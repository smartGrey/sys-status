#pragma once
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace hearing {

// Preserve the original curve through 18 dB. Above it, suppress near-background
// bands more strongly, while prominent events progressively regain protection.
inline float enhancedNoiseGain(float gain, float prominenceDB, float reductionDB) noexcept {
    if (reductionDB <= 18) return gain;
    const float strength = std::clamp((reductionDB-18)/12, 0.f, 1.f);
    const float t = std::clamp((prominenceDB-3)/9, 0.f, 1.f);
    const float protection = t*t*(3-2*t);
    return std::max(std::pow(10.f,-reductionDB/20), std::pow(gain,1+2*strength*(1-protection)));
}

// Capture-thread owned. Allocation/copying is confined to prepare/commit, with
// callbacks stopped. This is an MCRA-inspired estimator, not a speech classifier.
class NoiseModel {
    std::vector<float> smooth_, minimum_, temporary_, presence_;
    size_t age_ = 0, period_ = 1;
    float powerAlpha_ = 0, presenceAlpha_ = 0, noiseAlpha_ = 0;
public:
    std::vector<float> power;
    void prepare(size_t bins, double hopSeconds) {
        power.assign(bins, 1e-12f); smooth_ = minimum_ = temporary_ = power;
        presence_.assign(bins, 0); age_ = 0;
        period_ = std::max<size_t>(1, std::lround(.75 / hopSeconds));
        powerAlpha_ = std::exp(-hopSeconds / .020);
        presenceAlpha_ = std::exp(-hopSeconds / .050);
        noiseAlpha_ = std::exp(-hopSeconds / .6);
    }
    void reset() noexcept { age_ = 0; std::fill(presence_.begin(), presence_.end(), 0); }
    void observe(const std::vector<float>& input) noexcept {
        for (size_t k = 0; k < power.size(); ++k) {
            const float p = std::max(input[k], 1e-12f);
            if (!age_) { power[k] = smooth_[k] = minimum_[k] = temporary_[k] = p; continue; }
            smooth_[k] = powerAlpha_ * smooth_[k] + (1-powerAlpha_) * p;
            minimum_[k] = std::min(minimum_[k], smooth_[k]);
            temporary_[k] = std::min(temporary_[k], smooth_[k]);
            const float signal = smooth_[k] > 3 * std::max(minimum_[k], 1e-12f) ? 1 : 0;
            presence_[k] = presenceAlpha_*presence_[k] + (1-presenceAlpha_)*signal;
            const float alpha = noiseAlpha_ + (1-noiseAlpha_)*presence_[k];
            power[k] = std::max(1e-12f, alpha*power[k] + (1-alpha)*p);
            if (age_ % period_ == 0) {
                minimum_[k] = std::min(temporary_[k], smooth_[k]);
                temporary_[k] = smooth_[k];
            }
        }
        ++age_;
    }
};

struct CalibrationResult {
    uint64_t request = 0;
    int status = 0; // 0 collecting, 1 complete, -1 insufficient stable data
    float progress = 0, normalDB = 9;
};

class EnvironmentProcessor {
    static constexpr size_t bands = 24;
    FFTSetup fft_ = nullptr;
    size_t n_ = 0, hop_ = 0, log2_ = 0, cursor_ = 0, hopCursor_ = 0;
    uint64_t streamFrames_ = 0, learnedFrames_ = 0, calibrationFrames_ = 0, validFrames_ = 0;
    double rate_ = 0;
    float powerScale_ = 0, smoothAlpha_ = 0, closeAlpha_ = 0;
    std::vector<float> input_, ola_, window_, real_, imaginary_, time_, spectrum_, smoothed_;
    std::vector<unsigned> bandIndex_;
    std::vector<float> bandFraction_;
    std::array<float, bands> bandPower_{}, bandNoise_{}, gains_{}, targets_{}, prominence_{};
    std::array<uint32_t, 601> histogram_{}; // 0..60 dB in 0.1 dB bins
    NoiseModel active_, candidate_;
    CalibrationResult calibration_;
    float score_ = 0, rawDB_ = -120, reductionDB_ = 12;
    bool ready_ = false;

    static float erb(float f) noexcept { return 21.4f * std::log10(1 + .00437f*f); }
    void analyze() noexcept {
        for (size_t i = 0; i < n_; ++i) time_[i] = input_[(cursor_+i)%n_] * window_[i];
        DSPSplitComplex split{real_.data(), imaginary_.data()};
        vDSP_ctoz(reinterpret_cast<const DSPComplex*>(time_.data()), 2, &split, 1, n_/2);
        vDSP_fft_zrip(fft_, &split, 1, log2_, FFT_FORWARD);
        spectrum_[0] = real_[0]*real_[0]*powerScale_*.5f;
        spectrum_[n_/2] = imaginary_[0]*imaginary_[0]*powerScale_*.5f;
        for (size_t k = 1; k < n_/2; ++k)
            spectrum_[k] = (real_[k]*real_[k]+imaginary_[k]*imaginary_[k])*powerScale_;
        float total = 0;
        for (size_t k=0; k<spectrum_.size(); ++k) {
            total += spectrum_[k];
            smoothed_[k] = smoothAlpha_*smoothed_[k] + (1-smoothAlpha_)*spectrum_[k];
        }
        rawDB_ = 10*std::log10(std::max(total, 1e-12f));
        const bool measuring = calibration_.request != 0;
        NoiseModel& model = measuring ? candidate_ : active_;
        if (!measuring || calibration_.status == 0) model.observe(spectrum_);
        bandPower_.fill(0); bandNoise_.fill(0);
        for (size_t k=1; k<spectrum_.size(); ++k) {
            const float hz = float(k*rate_/n_);
            if (hz < 20 || hz > 20000) continue;
            const auto b = bandIndex_[k]; const float f = bandFraction_[k];
            bandPower_[b] += smoothed_[k]*(1-f); bandNoise_[b] += model.power[k]*(1-f);
            bandPower_[b+1] += smoothed_[k]*f; bandNoise_[b+1] += model.power[k]*f;
        }
        score_ = 0;
        const float floor = std::pow(10.f, -reductionDB_/20);
        for (size_t b=0; b<bands; ++b) {
            const float noise = std::max(bandNoise_[b], 1e-10f);
            const float ratio = bandPower_[b]/noise;
            prominence_[b] = 10*std::log10(std::max(1.f, ratio));
            score_ = std::max(score_, prominence_[b]);
            targets_[b] = std::max(floor, std::sqrt(std::max(0.f, 1-noise/std::max(bandPower_[b], 1e-10f))));
        }
        for (size_t b=0; b<bands; ++b) {
            // Release suppression immediately for an event; reapply it gently.
            const float ordinary = std::max(targets_[b], .5f*(targets_[b ? b-1 : b]+targets_[std::min(b+1,bands-1)]));
            const float target = enhancedNoiseGain(ordinary, prominence_[b], reductionDB_);
            gains_[b] = target > gains_[b] ? target : closeAlpha_*gains_[b]+(1-closeAlpha_)*target;
        }
        if (measuring && calibration_.status == 0) {
            calibrationFrames_ += hop_;
            calibration_.progress = std::min(1.f, float(calibrationFrames_/(5*rate_)));
            // The first second initializes the candidate. Large transients and
            // digital silence are not accepted as background observations.
            if (calibrationFrames_ > rate_ && rawDB_ > -110 && score_ < 12) {
                validFrames_ += hop_;
                ++histogram_[std::clamp<int>(int(std::lround(score_*10)),0,600)];
            }
            if (calibrationFrames_ >= 5*rate_) {
                calibration_.status = validFrames_ >= 3*rate_ ? 1 : -1;
                uint32_t count=0; for (auto value: histogram_) count+=value;
                uint32_t cumulative=0;
                for (size_t i=0; i<histogram_.size(); ++i) {
                    cumulative+=histogram_[i];
                    if (cumulative >= std::max(1u, uint32_t(std::ceil(count*.9)))) {
                        calibration_.normalDB = std::clamp(std::round(float(i)/10+6),6.f,27.f); break;
                    }
                }
            }
        } else if (!measuring) {
            learnedFrames_ += hop_;
            ready_ = learnedFrames_ >= 2*rate_;
        }
        // Identical WOLA path at 0 dB: changing reduction never changes latency.
        if (reductionDB_ > 0 && (ready_ || measuring)) {
            real_[0] *= gains_[0]; imaginary_[0] *= gains_[bands-1];
            for (size_t k=1; k<n_/2; ++k) {
                const auto b=bandIndex_[k]; const float f=bandFraction_[k];
                const float g=gains_[b]*(1-f)+gains_[b+1]*f;
                real_[k]*=g; imaginary_[k]*=g;
            }
        }
        vDSP_fft_zrip(fft_, &split, 1, log2_, FFT_INVERSE);
        vDSP_ztoc(&split,1,reinterpret_cast<DSPComplex*>(time_.data()),2,n_/2);
        // Forward real FFT scales by 2; inverse by N. Four overlapping
        // sqrt-Hann windows have sum of squared windows == 2.
        for (size_t i=0; i<n_; ++i) ola_[(cursor_+i)%n_] += time_[i]*window_[i]/float(4*n_);
    }
public:
    EnvironmentProcessor() = default;
    EnvironmentProcessor(const EnvironmentProcessor&) = delete;
    EnvironmentProcessor& operator=(const EnvironmentProcessor&) = delete;
    ~EnvironmentProcessor() { if (fft_) vDSP_destroy_fftsetup(fft_); }
    bool prepare(double rate, bool resetModel) {
        const bool changed = rate != rate_ || !fft_;
        rate_=rate; n_=1; log2_=0;
        while (n_ < rate*.016) { n_*=2; ++log2_; }
        hop_=n_/4;
        if (changed) {
            if (fft_) vDSP_destroy_fftsetup(fft_);
            fft_=vDSP_create_fftsetup(log2_, kFFTRadix2);
            if (!fft_) return false;
            active_.prepare(n_/2+1,hop_/rate); candidate_.prepare(n_/2+1,hop_/rate);
        }
        if (changed || resetModel) { active_.reset(); ready_=false; learnedFrames_=0; }
        input_.assign(n_,0); ola_.assign(n_,0); window_.resize(n_); time_.resize(n_);
        real_.resize(n_/2); imaginary_.resize(n_/2); spectrum_.assign(n_/2+1,0); smoothed_=spectrum_;
        bandIndex_.resize(n_/2+1); bandFraction_.resize(n_/2+1);
        float windowPower=0;
        for (size_t i=0; i<n_; ++i) { window_[i]=std::sqrt(.5f-.5f*std::cos(2*M_PI*i/n_)); windowPower+=window_[i]*window_[i]; }
        powerScale_=.5f/float(n_*windowPower);
        for (size_t k=0; k<bandIndex_.size(); ++k) {
            const float coordinate=std::min(float(bands-1), erb(float(k*rate/n_))/erb(float(std::min(20000.,rate/2)))*(bands-1));
            bandIndex_[k]=std::min(unsigned(coordinate),unsigned(bands-2));
            bandFraction_[k]=coordinate-bandIndex_[k];
        }
        smoothAlpha_=std::exp(-double(hop_)/rate/.020); closeAlpha_=std::exp(-double(hop_)/rate/.100);
        gains_.fill(1); cursor_=hopCursor_=0; streamFrames_=0; score_=0; rawDB_=-120;
        calibration_={};
        return true;
    }
    void setReduction(float db) noexcept { reductionDB_=std::clamp(std::isfinite(db)?db:12,0.f,30.f); }
    void setCalibrationRequest(uint64_t request) noexcept {
        if (request == calibration_.request) return;
        calibration_={}; calibration_.request=request;
        calibrationFrames_=validFrames_=0; histogram_.fill(0);
        if (request) candidate_.reset();
    }
    // Only called while callbacks are stopped, after checking the request token.
    bool commitCalibration(uint64_t request) {
        if (calibration_.request != request || calibration_.status != 1) return false;
        active_=candidate_; ready_=true; learnedFrames_=uint64_t(2*rate_); calibration_={}; return true;
    }
    float process(float x) noexcept {
        const float y=ola_[cursor_]; ola_[cursor_]=0;
        input_[cursor_]=std::clamp(std::isfinite(x)?x:0,-1.f,1.f);
        cursor_=(cursor_+1)%n_; ++streamFrames_;
        if (++hopCursor_ == hop_) { hopCursor_=0; if (streamFrames_>=n_) analyze(); }
        return y;
    }
    bool ready() const noexcept { return ready_ && !calibration_.request; }
    float scoreDB() const noexcept { return score_; }
    float rawDB() const noexcept { return rawDB_; }
    float latencyMS() const noexcept { return float(1000*n_/rate_); }
    size_t delayFrames() const noexcept { return n_; }
    CalibrationResult calibration() const noexcept { return calibration_; }
};
}
