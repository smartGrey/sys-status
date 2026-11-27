#include "HearingAudio.h"
#include "DSP.hpp"
#include "Environment.hpp"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <array>
#include <cstring>
#include <memory>

namespace {
template<typename T> bool get(AudioObjectID id, AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope, T &value) {
    AudioObjectPropertyAddress a{selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value) == noErr;
}
bool physicalOutput(AudioDeviceID id) {
    UInt32 transport = 0, alive = 0;
    if (!get(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, alive) || !alive ||
        !get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, transport)) return false;
    if (transport == kAudioDeviceTransportTypeBuiltIn) {
        AudioObjectPropertyAddress address{kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
                                           kAudioObjectPropertyElementMain};
        UInt32 bytes = 0;
        if (AudioObjectGetPropertyDataSize(id, &address, 0, nullptr, &bytes) != noErr) return false;
        std::vector<AudioStreamID> streams(bytes / sizeof(AudioStreamID));
        if (AudioObjectGetPropertyData(id, &address, 0, nullptr, &bytes, streams.data()) != noErr) return false;
        bool headphone = false;
        for (auto s: streams) {
            UInt32 terminal = 0;
            get(s, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal, terminal);
            if (terminal == kAudioStreamTerminalTypeSpeaker) return false;
            headphone |= terminal == kAudioStreamTerminalTypeHeadphones;
        }
        UInt32 jack = 0;
        if (get(id, kAudioDevicePropertyJackIsConnected, kAudioObjectPropertyScopeOutput, jack) && !jack)
            return false;
        // Apple Silicon exposes a dedicated headphone endpoint; some versions
        // omit its terminal type. Never infer this from a localized display name.
        CFStringRef uid = nullptr;
        if (get(id, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, uid) && uid) {
            headphone |= CFEqual(uid, CFSTR("BuiltInHeadphoneOutputDevice"));
            CFRelease(uid);
        }
        return headphone;
    }
    switch (transport) {
        case kAudioDeviceTransportTypeUSB: case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE: case kAudioDeviceTransportTypePCI:
        case kAudioDeviceTransportTypeFireWire: case kAudioDeviceTransportTypeHDMI:
        case kAudioDeviceTransportTypeDisplayPort: case kAudioDeviceTransportTypeThunderbolt:
            return true;
        default: return false;
    }
}
AudioStreamBasicDescription format(double rate, UInt32 channels) {
    AudioStreamBasicDescription f{};
    f.mSampleRate=rate; f.mFormatID=kAudioFormatLinearPCM;
    f.mFormatFlags=UInt32(kAudioFormatFlagsNativeFloatPacked) | UInt32(kAudioFormatFlagIsNonInterleaved);
    f.mBytesPerPacket=sizeof(float); f.mFramesPerPacket=1; f.mBytesPerFrame=sizeof(float);
    f.mChannelsPerFrame=channels; f.mBitsPerChannel=32;
    return f;
}
double latency(AudioDeviceID device, AudioObjectPropertyScope scope, double rate) {
    UInt32 deviceFrames=0, safety=0, buffer=0;
    get(device, kAudioDevicePropertyLatency, scope, deviceFrames);
    get(device, kAudioDevicePropertySafetyOffset, scope, safety);
    get(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, buffer);
    AudioObjectPropertyAddress a{kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain};
    UInt32 bytes=0, streamFrames=0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &bytes)==noErr) {
        std::vector<AudioStreamID> streams(bytes/sizeof(AudioStreamID));
        if (AudioObjectGetPropertyData(device, &a, 0, nullptr, &bytes, streams.data())==noErr)
            for (auto stream: streams) {
                UInt32 n=0;
                get(stream,kAudioStreamPropertyLatency,kAudioObjectPropertyScopeGlobal,n);
                streamFrames=std::max(streamFrames,n);
            }
    }
    return 1000.0 * (deviceFrames+safety+buffer+streamFrames) / rate;
}
}

struct HearingEngine {
    AudioUnit input=nullptr, output=nullptr;
    UInt32 maxFrames=0, inputChannels=0;
    std::vector<uint8_t> bufferListStorage;
    std::vector<float> captureStorage, monoStorage, outputStorage;
    hearing::Gate gate;
    hearing::EnvironmentProcessor environment;
    std::atomic<bool> resetEnvironment{true}, environmentReady{false};
    std::atomic<float> prominence{0}, environmentLatency{0};
    std::atomic<uint64_t> calibrationRequest{0}, calibrationResultRequest{0};
    std::atomic<int32_t> calibrationStatus{0};
    std::atomic<float> calibrationProgress{0}, calibrationNormal{9};
    hearing::StreamBridge bridge;
    std::atomic<float> threshold{9}, gain{6}, hold{1}, reduction{12};
    std::atomic<float> level{-120}, envelope{0}, inputRate{0}, outputRate{0}, deviceLatency{0};
    std::atomic<float> inputPeakDB{-120}, maximumInputPeakDB{-120};
    std::atomic<uint64_t> inputClippedSamples{0};
    std::atomic<double> inputClock{1};
    std::atomic<uint64_t> frames{0}, outputFrames{0}, callbackErrors{0};
    std::atomic<int32_t> lastError{0};
    std::atomic<bool> allowed{false}, running{false};
    bool captureOnly=true;

    void error(OSStatus status) noexcept {
        lastError.store(status); callbackErrors.fetch_add(1); allowed.store(false);
    }
    static OSStatus capture(void *context, AudioUnitRenderActionFlags *flags,
                            const AudioTimeStamp *time, UInt32 bus, UInt32 count, AudioBufferList *) {
        auto &e = *static_cast<HearingEngine *>(context);
        if (count > e.maxFrames) { e.error(kAudioUnitErr_TooManyFramesToProcess); return noErr; }
        auto *list = reinterpret_cast<AudioBufferList *>(e.bufferListStorage.data());
        for (UInt32 ch=0; ch<e.inputChannels; ++ch) {
            list->mBuffers[ch].mData=e.captureStorage.data()+ch*e.maxFrames;
            list->mBuffers[ch].mDataByteSize=count*sizeof(float);
        }
        const auto status=AudioUnitRender(e.input,flags,time,bus,count,list);
        if (status!=noErr) { e.error(status); return noErr; }
        const double clock = time->mRateScalar;
        e.inputClock.store((time->mFlags & kAudioTimeStampRateScalarValid) &&
            std::isfinite(clock) && clock > .99 && clock < 1.01 ? clock : 1,
            std::memory_order_relaxed);
        e.gate.setParameters({e.threshold.load(), e.gain.load(), e.hold.load()});
        e.environment.setReduction(e.reduction.load());
        e.environment.setCalibrationRequest(e.calibrationRequest.load(std::memory_order_acquire));
        float peak=0;
        uint64_t clipped=0;
        for (UInt32 i=0; i<count; ++i) {
            float x=0;
            for (UInt32 ch=0; ch<e.inputChannels; ++ch) {
                const float sample=e.captureStorage[ch*e.maxFrames+i];
                if (!std::isfinite(sample)) continue;
                peak=std::max(peak,std::abs(sample));
                if (std::abs(sample)>=.999f) ++clipped;
                x += sample / e.inputChannels;
            }
            const float processed=e.environment.process(x);
            e.monoStorage[i]=e.gate.process(processed,e.environment.scoreDB(),e.environment.ready());
        }
        const float peakDB=20*std::log10(std::max(1e-6f,peak));
        e.inputPeakDB.store(peakDB,std::memory_order_relaxed);
        e.maximumInputPeakDB.store(std::max(e.maximumInputPeakDB.load(),peakDB),std::memory_order_relaxed);
        e.inputClippedSamples.fetch_add(clipped,std::memory_order_relaxed);
        if (!e.captureOnly) e.bridge.push(e.monoStorage.data(), count);
        e.level.store(e.environment.rawDB(), std::memory_order_relaxed);
        e.prominence.store(e.environment.scoreDB(), std::memory_order_relaxed);
        e.environmentReady.store(e.environment.ready(), std::memory_order_relaxed);
        const auto calibration=e.environment.calibration();
        // Publish a completed result only once. Release of the request ID makes
        // its immutable payload visible to snapshot readers.
        e.calibrationProgress.store(calibration.progress);
        if (calibration.status && e.calibrationResultRequest.load()!=calibration.request) {
            e.calibrationNormal.store(calibration.normalDB);
            e.calibrationStatus.store(calibration.status);
            e.calibrationResultRequest.store(calibration.request,std::memory_order_release);
        }
        e.envelope.store(e.gate.envelope(), std::memory_order_relaxed);
        e.frames.fetch_add(count, std::memory_order_relaxed);
        return noErr;
    }
    static OSStatus playback(void *context, AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *time, UInt32, UInt32 count, AudioBufferList *data) {
        auto &e=*static_cast<HearingEngine *>(context);
        e.outputFrames.fetch_add(count, std::memory_order_relaxed);
        for (UInt32 b=0; b<data->mNumberBuffers; ++b)
            if (data->mBuffers[b].mData) std::memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        if (count>e.maxFrames) { e.error(kAudioUnitErr_TooManyFramesToProcess); return noErr; }
        const double outputClock=(time->mFlags & kAudioTimeStampRateScalarValid) ? time->mRateScalar : 1;
        e.bridge.render(e.outputStorage.data(), count,
                       outputClock>0 ? e.inputClock.load()/outputClock : 1);
        if (!e.allowed.load(std::memory_order_acquire)) {
            e.bridge.outputPeakDB.store(-120,std::memory_order_relaxed);
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        }
        for (UInt32 b=0; b<data->mNumberBuffers; ++b) {
            auto &buffer=data->mBuffers[b];
            if (!buffer.mData || buffer.mDataByteSize < count*buffer.mNumberChannels*sizeof(float)) {
                e.error(kAudio_ParamError); return noErr;
            }
            auto *out=static_cast<float *>(buffer.mData);
            for (UInt32 i=0; i<count; ++i)
                for (UInt32 ch=0; ch<buffer.mNumberChannels; ++ch)
                    out[i*buffer.mNumberChannels+ch]=e.outputStorage[i];
        }
        return noErr;
    }
    void stop() {
        allowed.store(false);
        if (output) { AudioOutputUnitStop(output); AudioUnitUninitialize(output); AudioComponentInstanceDispose(output); output=nullptr; }
        if (input) { AudioOutputUnitStop(input); AudioUnitUninitialize(input); AudioComponentInstanceDispose(input); input=nullptr; }
        running.store(false); level.store(-120); envelope.store(0);
    }
};

namespace {
OSStatus createUnit(AudioUnit &unit, AudioDeviceID device, bool input,
                    double &rate, UInt32 &channels) {
    AudioComponentDescription description{kAudioUnitType_Output,kAudioUnitSubType_HALOutput,
                                         kAudioUnitManufacturer_Apple,0,0};
    auto component=AudioComponentFindNext(nullptr,&description);
    if (!component) return kAudio_ParamError;
    OSStatus status=AudioComponentInstanceNew(component,&unit);
    if (status) return status;
    UInt32 enabled=input ? 1 : 0, disabled=input ? 0 : 1;
    status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&enabled,sizeof(enabled));
    if (status) return status;
    status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&disabled,sizeof(disabled));
    if (status) return status;
    status=AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof(device));
    if (status) return status;
    AudioStreamBasicDescription hardware{};
    UInt32 size=sizeof(hardware);
    status=AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,
        input ? kAudioUnitScope_Input : kAudioUnitScope_Output, input ? 1 : 0,&hardware,&size);
    if (status) return status;
    rate=hardware.mSampleRate;
    channels=input ? hardware.mChannelsPerFrame : std::min<UInt32>(hardware.mChannelsPerFrame,2);
    if (!std::isfinite(rate) || rate<8000 || rate>192000 || channels<1 || channels>8) return kAudioUnitErr_FormatNotSupported;
    auto client=format(rate, channels);
    return AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,
        input ? kAudioUnitScope_Output : kAudioUnitScope_Input,input ? 1 : 0,&client,sizeof(client));
}
}
extern "C" {
HearingEngine *HearingCreate() { return new HearingEngine; }
void HearingDestroy(HearingEngine *engine) { if (engine) { engine->stop(); delete engine; } }
int32_t HearingStart(HearingEngine *engine, uint32_t inputDevice, uint32_t outputDevice) {
    if (!engine) return kAudio_ParamError;
    auto &e=*engine;
    e.stop();
    e.frames.store(0); e.outputFrames.store(0); e.callbackErrors.store(0); e.lastError.store(0); e.inputClock.store(1);
    e.deviceLatency.store(0); e.inputRate.store(0); e.outputRate.store(0);
    e.inputPeakDB.store(-120); e.maximumInputPeakDB.store(-120); e.inputClippedSamples.store(0);
    UInt32 transport=0;
    if (!get(inputDevice,kAudioDevicePropertyTransportType,kAudioObjectPropertyScopeGlobal,transport) ||
        transport!=kAudioDeviceTransportTypeBuiltIn) return kAudioHardwareBadDeviceError;
    if (outputDevice && !physicalOutput(outputDevice)) return kAudioHardwareBadDeviceError;
    UInt32 noHog=0, canSleep=1;
    AudioObjectPropertyAddress hog{kAudioHardwarePropertyHogModeIsAllowed,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject,&hog,0,nullptr,sizeof(noHog),&noHog);
    AudioObjectPropertyAddress sleep{kAudioHardwarePropertySleepingIsAllowed,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject,&sleep,0,nullptr,sizeof(canSleep),&canSleep);
    e.captureOnly=outputDevice==0;
    double inputRate=0, outputRate=48000;
    UInt32 outputChannels=0, inputBuffer=512, outputBuffer=512;
    OSStatus status=createUnit(e.input,inputDevice,true,inputRate,e.inputChannels);
    if (!status && outputDevice) status=createUnit(e.output,outputDevice,false,outputRate,outputChannels);
    if (status) { e.stop(); e.lastError.store(status); return status; }
    get(inputDevice,kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,inputBuffer);
    if (outputDevice) get(outputDevice,kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,outputBuffer);
    UInt32 inputMax=4096, outputMax=4096, size=sizeof(UInt32);
    AudioUnitGetProperty(e.input,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&inputMax,&size);
    if (e.output) AudioUnitGetProperty(e.output,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&outputMax,&size);
    e.maxFrames=std::max({inputMax,outputMax,inputBuffer,outputBuffer,UInt32(4096)});
    if (e.maxFrames>65536) { e.stop(); return kAudioUnitErr_FormatNotSupported; }
    e.bufferListStorage.resize(offsetof(AudioBufferList,mBuffers)+sizeof(AudioBuffer)*e.inputChannels);
    auto *list=reinterpret_cast<AudioBufferList *>(e.bufferListStorage.data());
    list->mNumberBuffers=e.inputChannels;
    for (UInt32 ch=0; ch<e.inputChannels; ++ch) list->mBuffers[ch].mNumberChannels=1;
    e.captureStorage.resize(e.maxFrames*e.inputChannels);
    e.monoStorage.resize(e.maxFrames); e.outputStorage.resize(e.maxFrames);
    e.gate.prepare(inputRate);
    if (!e.environment.prepare(inputRate,e.resetEnvironment.exchange(false))) { e.stop(); return kAudio_MemFullError; }
    e.environmentLatency.store(e.environment.latencyMS());
    e.environmentReady.store(e.environment.ready());
    e.calibrationResultRequest.store(0); e.calibrationStatus.store(0); e.calibrationProgress.store(0);
    e.bridge.prepare(inputRate,outputRate,inputBuffer,outputBuffer);
    e.inputRate.store(float(inputRate)); e.outputRate.store(outputDevice ? float(outputRate) : 0);
    e.deviceLatency.store(float(latency(inputDevice,kAudioObjectPropertyScopeInput,inputRate)
        + (outputDevice ? latency(outputDevice,kAudioObjectPropertyScopeOutput,outputRate) : 0)));
    AURenderCallbackStruct in{HearingEngine::capture,&e}, out{HearingEngine::playback,&e};
    status=AudioUnitSetProperty(e.input,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,0,&in,sizeof(in));
    if (!status && e.output) status=AudioUnitSetProperty(e.output,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&out,sizeof(out));
    if (!status) status=AudioUnitInitialize(e.input);
    if (!status && e.output) status=AudioUnitInitialize(e.output);
    if (!status) status=AudioOutputUnitStart(e.input);
    if (!status && e.output) status=AudioOutputUnitStart(e.output);
    if (status) { e.stop(); e.lastError.store(status); return status; }
    e.running.store(true);
    return noErr;
}
void HearingStop(HearingEngine *e) { if (e) e->stop(); }
void HearingSetParameters(HearingEngine *e, HearingParameters p) {
    if (!e) return;
    e->threshold.store(std::isfinite(p.thresholdDB) ? std::clamp(p.thresholdDB,3.f,30.f) : 9);
    e->gain.store(std::isfinite(p.gainDB) ? std::clamp(p.gainDB,-12.f,36.f) : 6);
    e->hold.store(std::isfinite(p.holdSeconds) ? std::clamp(p.holdSeconds,.2f,3.f) : 1);
    e->reduction.store(std::isfinite(p.noiseReductionDB) ? std::clamp(p.noiseReductionDB,0.f,30.f) : 12);
}
void HearingSetOutputAllowed(HearingEngine *e, int32_t allowed) { if(e) e->allowed.store(allowed!=0,std::memory_order_release); }
void HearingRequestCalibration(HearingEngine *e, uint64_t request) {
    if (e) e->calibrationRequest.store(request,std::memory_order_release);
}
void HearingInvalidateEnvironment(HearingEngine *e) { if(e) e->resetEnvironment.store(true); }
int32_t HearingCommitCalibration(HearingEngine *e, uint64_t request) {
    if (!e || e->running.load() || !request || e->calibrationRequest.load()!=request) return 0;
    const bool accepted=e->environment.commitCalibration(request);
    uint64_t expected=request;
    e->calibrationRequest.compare_exchange_strong(expected,0);
    return accepted ? 1 : 0;
}
HearingSnapshot HearingReadSnapshot(HearingEngine *e) {
    HearingSnapshot s{};
    if (!e) return s;
    s.levelDB=e->level.load(); s.envelope=e->envelope.load();
    s.prominenceDB=e->prominence.load(); s.environmentReady=e->environmentReady.load();
    s.environmentLatencyMilliseconds=e->environmentLatency.load();
    s.calibrationRequest=e->calibrationResultRequest.load(std::memory_order_acquire);
    s.calibrationStatus=e->calibrationStatus.load(); s.calibrationNormalDB=e->calibrationNormal.load();
    s.calibrationProgress=e->calibrationProgress.load();
    s.queuedMilliseconds=e->bridge.queueMS.load(); s.deviceLatencyMilliseconds=e->deviceLatency.load();
    s.inputRate=e->inputRate.load(); s.outputRate=e->outputRate.load(); s.inputFrames=e->frames.load();
    s.outputFrames=e->outputFrames.load();
    s.inputPeakDB=e->inputPeakDB.load(); s.maximumInputPeakDB=e->maximumInputPeakDB.load();
    s.inputClippedSamples=e->inputClippedSamples.load();
    s.outputPeakDB=e->bridge.outputPeakDB.load(); s.gainReductionDB=e->bridge.gainReductionDB.load();
    s.processingLatencyMilliseconds=e->outputRate.load()>0 ? e->bridge.processingLatencyMS.load()+e->environmentLatency.load() : 0;
    s.underruns=e->bridge.underruns.load(); s.overflows=e->bridge.overflows.load();
    s.callbackErrors=e->callbackErrors.load(); s.lastError=e->lastError.load(); s.running=e->running.load();
    return s;
}
}
