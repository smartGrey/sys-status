#import <XCTest/XCTest.h>
#include "Environment.hpp"
#include "DSP.hpp"
#include <limits>

namespace {
struct Noise {
    uint32_t state = 42;
    float next() { state=1664525*state+1013904223; return float(int32_t(state))/2147483648.f; }
};
float background(int i, Noise& noise, double rate=48000) {
    return .035f*std::sin(2*M_PI*80*i/rate)+.002f*noise.next();
}
}
@interface EnvironmentTests : XCTestCase
@end
@implementation EnvironmentTests
- (void)testTransparentReconstructionAndDelay {
    for (double rate: {8000.,16000.,44100.,48000.,96000.,192000.}) {
        hearing::EnvironmentProcessor p; XCTAssertTrue(p.prepare(rate,true)); p.setReduction(0);
        XCTAssertLessThanOrEqual(p.latencyMS(),25);
        const int count=int(rate*.15), delay=int(p.delayFrames());
        std::vector<float> input(count); Noise random;
        double error=0;
        for (int i=0;i<count;++i) {
            input[i]=.1f*random.next();
            const float y=p.process(input[i]);
            if(i>2*delay) error=std::max(error,std::abs(double(y-input[i-delay])));
        }
        XCTAssertLessThan(error,1e-6);
    }
}
- (void)testWarmupAndEventDetectionDespiteDominantLowFrequencyNoise {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); Noise noise;
    float backgroundPeak=0, eventPeak=0;
    for(int i=0;i<48000*5;++i) {
        const bool event=i>=48000*3 && i<48000*4;
        const float x=background(i,noise)+(event ? .006f*std::sin(2*M_PI*1600*i/48000) : 0);
        p.process(x);
        if(i<48000) XCTAssertFalse(p.ready());
        if(i>=48000*2.5 && i<48000*3) backgroundPeak=std::max(backgroundPeak,p.scoreDB());
        if(event) eventPeak=std::max(eventPeak,p.scoreDB());
    }
    XCTAssertTrue(p.ready()); XCTAssertLessThan(backgroundPeak,9);
    XCTAssertGreaterThan(eventPeak,12);
    NSLog(@"Environment detection: background %.2f dB, weak event %.2f dB",backgroundPeak,eventPeak);
}
- (void)testReductionDoesNotChangeDetectionAndAttenuatesSteadyNoise {
    hearing::EnvironmentProcessor dry,wet; dry.prepare(48000,true); wet.prepare(48000,true);
    dry.setReduction(0); wet.setReduction(12); Noise noise;
    double dryPower=0,wetPower=0;
    for(int i=0;i<48000*5;++i) {
        const float x=background(i,noise);
        const float a=dry.process(x), b=wet.process(x);
        if(i>48000*4) { dryPower+=a*a; wetPower+=b*b; }
        if(i%256==0) XCTAssertEqual(dry.scoreDB(),wet.scoreDB());
    }
    const double reduction=10*std::log10(dryPower/wetPower);
    NSLog(@"Stationary background reduction: %.2f dB",reduction);
    XCTAssertGreaterThan(reduction,6); XCTAssertLessThanOrEqual(reduction,12.1);
}
- (void)testNoiseStepAdaptsWithoutDependingOnGate {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); Noise noise;
    double score=0; int count=0;
    for(int i=0;i<48000*14;++i) {
        p.process(background(i,noise)*(i>=48000*3 ? 4 : 1));
        if(i>48000*12 && i%256==0) { score+=p.scoreDB(); ++count; }
    }
    XCTAssertLessThan(score/count,6);
}
- (void)testChangingSpeechLikeSignalIsNotLearnedAway {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); p.setReduction(12); Noise noise;
    float latePeak=0;
    for(int i=0;i<48000*15;++i) {
        const double t=i/48000.;
        const float syllable=std::pow(std::max(0.,std::sin(2*M_PI*3*t)),.5);
        float speech=0;
        if(t>=3) for(int h=1;h<=12;++h)
            speech+=.015f/h*syllable*std::sin(2*M_PI*(170+7*std::sin(2*M_PI*.7*t))*h*t);
        p.process(background(i,noise)+speech);
        if(t>12) latePeak=std::max(latePeak,p.scoreDB());
    }
    XCTAssertGreaterThan(latePeak,9);
}
- (void)testCalibrationCommitCancelAndRequestIdentity {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); Noise noise;
    for(int i=0;i<48000*3;++i) p.process(background(i,noise));
    XCTAssertTrue(p.ready()); p.setCalibrationRequest(7);
    for(int i=0;i<48000*6;++i) p.process(background(i,noise));
    const auto result=p.calibration();
    XCTAssertEqual(result.request,7u); XCTAssertEqual(result.status,1);
    XCTAssertGreaterThanOrEqual(result.normalDB,6); XCTAssertLessThanOrEqual(result.normalDB,27);
    XCTAssertFalse(p.commitCalibration(6)); XCTAssertTrue(p.commitCalibration(7));
    XCTAssertTrue(p.ready());
    p.prepare(48000,false); XCTAssertTrue(p.ready());
    p.setCalibrationRequest(8); p.setCalibrationRequest(0);
    XCTAssertTrue(p.ready()); XCTAssertFalse(p.commitCalibration(8));
    p.prepare(48000,true); XCTAssertFalse(p.ready());
}
- (void)testSilenceCalibrationFailsWithoutReplacingActiveModel {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); Noise noise;
    for(int i=0;i<48000*3;++i) p.process(background(i,noise));
    p.setCalibrationRequest(1);
    for(int i=0;i<48000*6;++i) p.process(0);
    XCTAssertEqual(p.calibration().status,-1); XCTAssertFalse(p.commitCalibration(1));
    p.setCalibrationRequest(0); XCTAssertTrue(p.ready());
}
- (void)testNonfiniteInputAndParameterChangesStayFinite {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); Noise noise;
    for(int i=0;i<48000*3;++i) {
        if(i%1024==0) p.setReduction(i%3072 == 0 ? 0 : i%3072 == 1024 ? 18 : 30);
        const float x=i%137==0 ? std::numeric_limits<float>::quiet_NaN() : background(i,noise);
        const float y=p.process(x);
        XCTAssertTrue(std::isfinite(y)); XCTAssertLessThan(std::abs(y),1);
    }
}
- (void)testEnhancedCurvePreservesDailyRangeAndProtectsProminentEvents {
    for(float gain: {.02f,.1f,.3f,.7f,1.f}) {
        for(float db: {0.f,12.f,18.f}) for(float prominence: {0.f,6.f,12.f,30.f})
            XCTAssertEqual(hearing::enhancedNoiseGain(gain,prominence,db),gain);
        // Eligible gains are already bounded by the new maximum attenuation.
        if(gain >= std::pow(10.f,-30.f/20)) {
            XCTAssertEqualWithAccuracy(hearing::enhancedNoiseGain(gain,12,30),gain,1e-7);
            XCTAssertLessThanOrEqual(hearing::enhancedNoiseGain(gain,0,30),gain);
            XCTAssertGreaterThanOrEqual(hearing::enhancedNoiseGain(gain,0,30),std::pow(10.f,-30.f/20));
        }
    }
}
- (void)testHighReductionImprovesSteadyAndFluctuatingNoiseWithoutChangingDetection {
    for(int kind=0;kind<3;++kind) {
        hearing::EnvironmentProcessor normal,strong; normal.prepare(48000,true); strong.prepare(48000,true);
        normal.setReduction(18); strong.setReduction(30); Noise noise;
        double oldPower=0,newPower=0;
        for(int i=0;i<48000*8;++i) {
            const double t=i/48000.;
            float x=kind==0 ? background(i,noise) : kind==1 ? .02f*noise.next()
                : (.025f*std::sin(2*M_PI*110*t)+.018f*std::sin(2*M_PI*185*t)+.003f*noise.next())
                    * (1+.35f*std::sin(2*M_PI*.7*t));
            float a=normal.process(x),b=strong.process(x);
            if(i>48000*5) { oldPower+=a*a; newPower+=b*b; }
            if(i%256==0) XCTAssertEqual(normal.scoreDB(),strong.scoreDB());
        }
        const double extra=10*std::log10(oldPower/newPower);
        NSLog(@"Enhanced reduction kind %d: %.2f dB beyond 18",kind,extra);
        XCTAssertGreaterThan(extra,3);
        XCTAssertEqual(normal.delayFrames(),strong.delayFrames());
    }
}
- (void)testLowVoiceLikeEventsAndWeakReminderRemainDetectableAtMaximumReduction {
    hearing::EnvironmentProcessor normal,strong; normal.prepare(48000,true); strong.prepare(48000,true);
    normal.setReduction(18); strong.setReduction(30); Noise noise;
    double reminderOld=0,reminderNew=0; float voicePeak=0,reminderPeak=0;
    for(int i=0;i<48000*9;++i) {
        const double t=i/48000.;
        float x=background(i,noise);
        if(t>=3 && t<6) {
            const float syllable=std::sqrt(std::max(0.,std::sin(2*M_PI*3*t)));
            for(int h=1;h<=8;++h) x+=.02f/h*syllable*std::sin(2*M_PI*130*h*t);
        }
        if(t>=7 && t<8) x+=.012f*std::sin(2*M_PI*1600*t);
        const float a=normal.process(x),b=strong.process(x);
        if(t>=3 && t<6) voicePeak=std::max(voicePeak,strong.scoreDB());
        if(t>=7 && t<8) reminderPeak=std::max(reminderPeak,strong.scoreDB());
        // Measure the reminder's coherent component instead of total noise+signal power.
        if(t>=7.3 && t<7.9) {
            const double ref=std::sin(2*M_PI*1600*(i-int(strong.delayFrames()))/48000.);
            reminderOld+=a*ref; reminderNew+=b*ref;
        }
        if(i%256==0) XCTAssertEqual(normal.scoreDB(),strong.scoreDB());
    }
    XCTAssertGreaterThan(voicePeak,9); XCTAssertGreaterThan(reminderPeak,12);
    XCTAssertGreaterThan(std::abs(reminderNew/reminderOld),.9);
}
- (void)testLearningKeepsGateMutedAndZeroScoreClosesLowestThreshold {
    hearing::Gate gate; gate.prepare(48000); gate.setParameters({3,0,.2});
    for(int i=0;i<4800;++i) XCTAssertEqual(gate.process(.1,30,false),0);
    for(int i=0;i<4800;++i) gate.process(.1,10);
    XCTAssertEqual(gate.envelope(),1);
    for(int i=0;i<48000;++i) gate.process(.1,0);
    XCTAssertEqual(gate.envelope(),0);
}
- (void)testInterruptedBackgroundMeasurementDoesNotProduceRecommendation {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); p.setCalibrationRequest(99); Noise noise;
    for(int i=0;i<48000*6;++i) {
        const float burst=i>48000 && (i/4800)%2 ? .4f*noise.next() : 0;
        p.process(background(i,noise)+burst);
    }
    XCTAssertEqual(p.calibration().status,-1);
    XCTAssertFalse(p.commitCalibration(99));
}
- (void)testSpeechAtStartupDoesNotPermanentlyHideLaterEvents {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); Noise noise; float event=0;
    for(int i=0;i<48000*6;++i) {
        const bool speaking=i<48000 || (i>=48000*4 && i<48000*5);
        p.process(background(i,noise)+(speaking ? .02f*std::sin(2*M_PI*1400*i/48000) : 0));
        if(i>=48000*4 && i<48000*5) event=std::max(event,p.scoreDB());
    }
    XCTAssertGreaterThan(event,9);
}
- (void)testBroadbandHissIsReducedAndNoiseDropRecovers {
    hearing::EnvironmentProcessor p; p.prepare(48000,true); p.setReduction(12); Noise noise;
    double inputPower=0,outputPower=0; float lateScore=0;
    for(int i=0;i<48000*12;++i) {
        const float x=.02f*noise.next()*(i>48000*5 ? .25f : 1);
        const float y=p.process(x);
        if(i>48000*4 && i<48000*5) { inputPower+=x*x; outputPower+=y*y; }
        if(i>48000*11) lateScore=std::max(lateScore,p.scoreDB());
    }
    XCTAssertGreaterThan(10*std::log10(inputPower/outputPower),4);
    XCTAssertLessThan(lateScore,9);
}
@end
