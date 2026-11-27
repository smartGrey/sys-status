#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct HearingEngine HearingEngine;
typedef struct {
    float thresholdDB; // spectral prominence above background, 3..30 dB
    float gainDB;
    float holdSeconds;
    float noiseReductionDB;
} HearingParameters;
typedef struct {
    float levelDB; // unprocessed microphone RMS in dBFS
    float prominenceDB;
    float environmentLatencyMilliseconds;
    int32_t environmentReady;
    uint64_t calibrationRequest;
    int32_t calibrationStatus;
    float calibrationProgress;
    float calibrationNormalDB;
    float envelope;
    float queuedMilliseconds;
    float deviceLatencyMilliseconds;
    float inputRate;
    float outputRate;
    float inputPeakDB;
    float maximumInputPeakDB;
    float outputPeakDB;
    float gainReductionDB;
    float processingLatencyMilliseconds;
    uint64_t inputClippedSamples;
    uint64_t inputFrames;
    uint64_t outputFrames;
    uint64_t underruns;
    uint64_t overflows;
    uint64_t callbackErrors;
    int32_t lastError;
    int32_t running;
} HearingSnapshot;
HearingEngine *HearingCreate(void);
void HearingDestroy(HearingEngine *);
// Start/stop are serialized by the caller; all other operations are atomic.
// outputDevice == 0 is capture-only calibration. Playback always starts muted.
int32_t HearingStart(HearingEngine *, uint32_t inputDevice, uint32_t outputDevice);
void HearingStop(HearingEngine *);
void HearingSetParameters(HearingEngine *, HearingParameters);
void HearingSetOutputAllowed(HearingEngine *, int32_t allowed);
// Atomic commands, safe while running. A zero request cancels calibration.
void HearingRequestCalibration(HearingEngine *, uint64_t request);
void HearingInvalidateEnvironment(HearingEngine *);
// Lifecycle operation: caller must stop callbacks before committing a result.
int32_t HearingCommitCalibration(HearingEngine *, uint64_t request);
HearingSnapshot HearingReadSnapshot(HearingEngine *);
#ifdef __cplusplus
}
#endif
