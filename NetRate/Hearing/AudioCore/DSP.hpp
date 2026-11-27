#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

namespace hearing {
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);

struct GateParameters {
    float thresholdDB = 9, gainDB = 6, holdSeconds = 1;
};

// The detector owns spectral analysis. This class only controls the audible
// envelope and gain, so reduction strength cannot affect trigger decisions.
class Gate {
    double rate_ = 48000;
    uint64_t quietFrames_ = 0, holdFrames_ = 0;
    bool open_ = false;
    float envelope_ = 0, openDB_ = 9, closeDB_ = 6, gain_ = 1, targetGain_ = 1, gainAlpha_ = 0;
    float attackStep_ = 0, releaseStep_ = 0;
public:
    void prepare(double rate) {
        rate_ = rate; quietFrames_ = 0; open_ = false; envelope_ = 0;
        attackStep_ = float(1 / (rate * .010));
        releaseStep_ = float(1 / (rate * .150));
        gain_ = 1; gainAlpha_ = float(1 - std::exp(-1 / (rate * .020)));
        setParameters({});
    }
    void setParameters(GateParameters p) noexcept {
        openDB_ = std::clamp(p.thresholdDB, 3.f, 30.f);
        closeDB_ = std::max(0.f, openDB_ - 3);
        targetGain_ = std::pow(10.f, std::clamp(p.gainDB, -12.f, 36.f) / 20);
        holdFrames_ = uint64_t(std::clamp(p.holdSeconds, .2f, 3.f) * rate_);
    }
    float process(float x, float prominenceDB, bool ready = true) noexcept {
        if (!std::isfinite(x)) x = 0;
        if (!std::isfinite(prominenceDB)) prominenceDB = 0;
        if (!ready) { open_=false; quietFrames_=0; envelope_=0; }
        else if (prominenceDB >= openDB_) { open_ = true; quietFrames_ = 0; }
        else if (open_) {
            if (prominenceDB > closeDB_) quietFrames_ = 0;
            else if (++quietFrames_ >= holdFrames_) open_ = false;
        }
        envelope_ = open_ ? std::min(1.f, envelope_ + attackStep_)
                          : std::max(0.f, envelope_ - releaseStep_);
        gain_ += gainAlpha_ * (targetGain_ - gain_);
        return x * gain_ * envelope_;
    }
    float envelope() const noexcept { return envelope_; }
};

// A sliding peak detector followed by an equally long moving average of gain.
// Every gain contributing to a delayed sample has seen that sample's peak.
// This gives a smooth 5 ms attack without overshooting or shaping the waveform.
// Storage is allocated only by prepare(); reset/process are callback-safe.
class PeakLimiter {
    struct Peak { uint64_t index = 0; float magnitude = 0; };
    std::vector<Peak> peaks_;
    std::vector<float> delay_;
    std::vector<double> gains_;
    size_t cursor_ = 0, head_ = 0, peakCount_ = 0;
    uint64_t index_ = 0;
    double gain_ = 1, sum_ = 0, appliedGain_ = 1, releaseAlpha_ = 0;
public:
    static constexpr float ceiling = .7079458f; // -3 dBFS, unchanged headroom
    void prepare(double rate) {
        const size_t count = size_t(std::ceil(rate * .005)) + 1;
        peaks_.resize(count); delay_.resize(count); gains_.resize(count);
        releaseAlpha_ = 1 - std::exp(-1 / (rate * .100));
        reset();
    }
    void reset() noexcept {
        std::fill(delay_.begin(), delay_.end(), 0);
        std::fill(gains_.begin(), gains_.end(), 1);
        cursor_ = head_ = peakCount_ = 0; index_ = 0;
        gain_ = appliedGain_ = 1; sum_ = double(gains_.size());
    }
    float process(float x) noexcept {
        if (!std::isfinite(x)) x = 0;
        const size_t count = delay_.size();
        if (!count) return 0;
        while (peakCount_ && index_ - peaks_[head_].index >= count) {
            head_ = (head_ + 1) % count; --peakCount_;
        }
        const float magnitude = std::abs(x);
        while (peakCount_ && peaks_[(head_ + peakCount_ - 1) % count].magnitude <= magnitude)
            --peakCount_;
        peaks_[(head_ + peakCount_) % count] = {index_++, magnitude}; ++peakCount_;
        const double peak = peaks_[head_].magnitude;
        const double target = peak > ceiling ? double(ceiling) / peak : 1;
        gain_ = target < gain_ ? target : gain_ + releaseAlpha_ * (target - gain_);
        sum_ += gain_ - gains_[cursor_]; gains_[cursor_] = gain_;
        appliedGain_ = std::clamp(sum_ / count, 0.0, 1.0);
        delay_[cursor_] = x;
        cursor_ = (cursor_ + 1) % count;
        // The clamp catches rounding only; the detector guarantees the bound.
        return float(std::clamp(double(delay_[cursor_]) * appliedGain_, -double(ceiling), double(ceiling)));
    }
    double appliedGain() const noexcept { return appliedGain_; }
    size_t delayFrames() const noexcept { return delay_.empty() ? 0 : delay_.size() - 1; }
};

// SPSC: input owns write_, output owns read_. A full ring drops NEW input;
// it never races the reader by rewriting unread samples.
class StreamBridge {
    std::vector<float> samples_;
    alignas(64) std::atomic<uint64_t> write_{0};
    alignas(64) std::atomic<uint64_t> read_{0};
    double inputRate_ = 48000, outputRate_ = 48000, fraction_ = 0, errorEMA_ = 0;
    size_t target_ = 960;
    bool primed_ = false;
    float recoveryGain_ = 0;
    PeakLimiter limiter_;
public:
    std::atomic<uint64_t> underruns{0}, overflows{0};
    std::atomic<float> queueMS{0};
    std::atomic<float> outputPeakDB{-120}, gainReductionDB{0}, processingLatencyMS{0};
    void prepare(double inputRate, double outputRate, size_t inputFrames, size_t outputFrames) {
        inputRate_ = inputRate; outputRate_ = outputRate;
        target_ = size_t(std::max(inputRate * .030,
            3.0 * std::max(double(inputFrames), outputFrames * inputRate / outputRate))) + 4;
        samples_.assign(std::max<size_t>(size_t(inputRate * .5), target_ * 4), 0);
        write_.store(0); read_.store(0);
        fraction_ = 0; errorEMA_ = 0; primed_ = false; recoveryGain_ = 0;
        underruns.store(0); overflows.store(0); queueMS.store(0);
        limiter_.prepare(outputRate);
        outputPeakDB.store(-120); gainReductionDB.store(0);
        processingLatencyMS.store(float(1000 * limiter_.delayFrames() / outputRate));
    }
    void push(const float *source, size_t count) noexcept {
        const auto w = write_.load(std::memory_order_relaxed);
        const auto r = read_.load(std::memory_order_acquire);
        const size_t accepted = std::min(count, samples_.size() - size_t(w-r));
        for (size_t i=0; i<accepted; ++i) samples_[(w+i) % samples_.size()] = source[i];
        write_.store(w+accepted, std::memory_order_release);
        if (accepted != count) overflows.fetch_add(count-accepted, std::memory_order_relaxed);
    }
    // Cubic interpolation at the native device rates. Small clock/occupancy
    // corrections keep the queue bounded without touching hardware formats.
    void render(float *destination, size_t count, double clockRatio = 1) noexcept {
        auto r = read_.load(std::memory_order_relaxed);
        const auto w = write_.load(std::memory_order_acquire);
        size_t available = size_t(w-r);
        float outputPeak = 0;
        double minimumGain = 1;
        outputPeakDB.store(-120); gainReductionDB.store(0);
        if (available > target_ + size_t(inputRate_ * .100)) {
            r = w - target_; available = target_;
            fraction_ = 0; recoveryGain_ = 0; errorEMA_ = 0;
            limiter_.reset();
            overflows.fetch_add(1, std::memory_order_relaxed);
        }
        if (!primed_) {
            if (available < target_) {
                std::fill_n(destination, count, 0);
                read_.store(r, std::memory_order_release);
                queueMS.store(float(1000 * available / inputRate_));
                return;
            }
            primed_ = true;
        }
        const double alpha = std::min(1.0, count / (outputRate_ * 2));
        errorEMA_ += alpha * (double(available) - target_ - errorEMA_);
        const double correction = std::clamp(errorEMA_ / (inputRate_ * 2), -.003, .003);
        if (!std::isfinite(clockRatio)) clockRatio = 1;
        const double ratio = inputRate_ / outputRate_
            * std::clamp(clockRatio, .99, 1.01) * (1 + correction);
        const float fadeStep = float(1 / (outputRate_ * .010));
        for (size_t i=0; i<count; ++i) {
            if (w-r < 4) {
                std::fill(destination+i, destination+count, 0);
                underruns.fetch_add(1, std::memory_order_relaxed);
                r = w; fraction_ = 0; primed_ = false; recoveryGain_ = 0; errorEMA_ = 0;
                limiter_.reset();
                break;
            }
            const float p0 = samples_[r % samples_.size()];
            const float p1 = samples_[(r+1) % samples_.size()];
            const float p2 = samples_[(r+2) % samples_.size()];
            const float p3 = samples_[(r+3) % samples_.size()];
            const float t = float(fraction_);
            const float value = p1 + .5f*t*(p2-p0 + t*(2*p0-5*p1+4*p2-p3
                                 + t*(3*(p1-p2)+p3-p0)));
            recoveryGain_ = std::min(1.f, recoveryGain_ + fadeStep);
            destination[i] = limiter_.process(value) * recoveryGain_;
            outputPeak = std::max(outputPeak, std::abs(destination[i]));
            minimumGain = std::min(minimumGain, limiter_.appliedGain());
            fraction_ += ratio;
            const auto advance = uint64_t(fraction_);
            r += advance; fraction_ -= advance;
            if (r > w) { r = w; fraction_ = 0; }
        }
        read_.store(r, std::memory_order_release);
        queueMS.store(float(1000 * (w-r) / inputRate_), std::memory_order_relaxed);
        outputPeakDB.store(20 * std::log10(std::max(1e-6f, outputPeak)), std::memory_order_relaxed);
        gainReductionDB.store(float(-20 * std::log10(std::max(1e-12, minimumGain))), std::memory_order_relaxed);
    }
    size_t targetFrames() const { return target_; }
    size_t capacity() const { return samples_.size(); }
};
}
