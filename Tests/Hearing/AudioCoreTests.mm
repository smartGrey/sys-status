#import <XCTest/XCTest.h>
#include "DSP.hpp"
#include "HearingAudio.h"
#include <thread>
#include <limits>

@interface AudioCoreTests : XCTestCase
@end
@implementation AudioCoreTests
- (void)testGateThresholdHysteresisHoldAndRelease {
    hearing::Gate gate;
    gate.prepare(48000);
    gate.setParameters({9,0,1});
    for (int i=0;i<4800;++i) gate.process(.005f,3);
    XCTAssertEqual(gate.envelope(), 0);
    for (int i=0;i<2000;++i) gate.process(.04f,12);
    XCTAssertEqualWithAccuracy(gate.envelope(), 1, .001);
    for (int i=0;i<96000;++i) gate.process(.01f,7);
    XCTAssertEqualWithAccuracy(gate.envelope(), 1, .001);
    for (int i=0;i<24000;++i) gate.process(0,0);
    XCTAssertEqualWithAccuracy(gate.envelope(), 1, .001);
    for (int i=0;i<40000;++i) gate.process(0,0);
    XCTAssertEqualWithAccuracy(gate.envelope(), 0, .001);
}
- (void)testEnvelopeChangesAreBounded {
    hearing::Gate gate; gate.prepare(48000); gate.setParameters({3,0,.2});
    float previous=0;
    for (int i=0;i<30000;++i) {
        gate.process(i<1000 ? .1f : 0,i<1000 ? 12 : 0);
        const float now=gate.envelope();
        XCTAssertLessThanOrEqual(std::abs(now-previous), 1.f/480 + .00001f);
        previous=now;
    }
}
- (void)testNonfiniteInputCannotPoisonMeter {
    hearing::Gate gate; gate.prepare(44100);
    XCTAssertTrue(std::isfinite(gate.process(std::numeric_limits<float>::quiet_NaN(),12)));
    XCTAssertTrue(std::isfinite(gate.process(std::numeric_limits<float>::infinity(),12)));
    XCTAssertTrue(std::isfinite(gate.envelope()));
    hearing::PeakLimiter limiter; limiter.prepare(48000);
    for (float value: {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                      -100.f,-1.f,-.2f,0.f,.2f,1.f,100.f})
        XCTAssertTrue(std::isfinite(limiter.process(value)));
}
- (void)testLimiterPassesQuietSignalWithFiveMillisecondDelay {
    for (double rate: {8000.,44100.,48000.,96000.,192000.}) {
        hearing::PeakLimiter limiter; limiter.prepare(rate);
        const auto delay=limiter.delayFrames();
        XCTAssertLessThanOrEqual(1000*delay/rate,5.13);
        std::vector<float> input(10000);
        for (size_t i=0;i<input.size();++i) {
            input[i]=.3f*std::sin(2*M_PI*500*i/rate);
            const float y=limiter.process(input[i]);
            XCTAssertEqualWithAccuracy(y,i<delay ? 0 : input[i-delay],1e-6);
        }
    }
}
- (void)testLimiterContainsTransientsAndRecoversWithoutOldAudio {
    hearing::PeakLimiter limiter; limiter.prepare(48000);
    uint32_t random=1;
    for (int i=0;i<192000;++i) {
        random=random*1664525+1013904223;
        const float x=i%17000==0 ? 100 : float(int32_t(random))/2147483648.f*(i%24000<12000 ? 8 : .1f);
        const float y=limiter.process(x);
        XCTAssertTrue(std::isfinite(y));
        XCTAssertLessThanOrEqual(std::abs(y),hearing::PeakLimiter::ceiling+1e-6f);
    }
    limiter.reset();
    for (int i=0;i<1000;++i) XCTAssertEqual(limiter.process(0),0);
    for (int i=0;i<48000;++i) limiter.process(.1);
    XCTAssertEqualWithAccuracy(limiter.process(.1),.1,1e-6);
}
- (void)testOverloadedSineRemainsClean {
    for (double rate: {44100.,48000.,96000.}) {
        hearing::PeakLimiter limiter; limiter.prepare(rate);
        const int count=int(rate/10);
        std::vector<float> output(count);
        for (int i=0;i<int(rate)+count;++i) {
            const float y=limiter.process(float(std::pow(10,4.0/20)*std::sin(2*M_PI*1000*i/rate)));
            if(i>=int(rate)) output[i-int(rate)]=y;
        }
        double fundamental=0,harmonics=0;
        for(int h=1;h<=20;++h) {
            double sine=0,cosine=0;
            for(int i=0;i<count;++i) {
                sine+=output[i]*std::sin(2*M_PI*1000*h*i/rate);
                cosine+=output[i]*std::cos(2*M_PI*1000*h*i/rate);
            }
            const double power=sine*sine+cosine*cosine;
            if(h==1) fundamental=power; else harmonics+=power;
        }
        const double thd=std::sqrt(harmonics/fundamental);
        NSLog(@"Limiter %.0f Hz: THD %.6f%%",rate,thd*100);
        XCTAssertLessThan(thd,.001);
        XCTAssertGreaterThan(std::sqrt(fundamental)*2/count,.69);
    }
}
- (void)testThirtySixDecibelGainAndSmoothChanges {
    hearing::Gate gate; gate.prepare(48000); gate.setParameters({3,36,.2});
    for(int i=0;i<48000;++i) gate.process(.001f,12);
    XCTAssertEqualWithAccuracy(gate.process(.001f,12),.0630957,.0001);
    hearing::PeakLimiter limiter; limiter.prepare(48000);
    for(int i=0;i<96000;++i) {
        if(i%4800==0) gate.setParameters({3,i%9600 ? 36.f : -12.f,.2});
        const float y=limiter.process(gate.process(.1f*std::sin(2*M_PI*1000*i/48000),12));
        XCTAssertTrue(std::isfinite(y));
        XCTAssertLessThanOrEqual(std::abs(y),hearing::PeakLimiter::ceiling+1e-6f);
    }
}
- (void)testSampleRateConversionPreservesFrequency {
    hearing::StreamBridge bridge; bridge.prepare(44100,48000,441,480);
    std::vector<float> input(441), output(480);
    uint64_t position=0, crossings=0; float previous=0;
    for (int block=0;block<400;++block) {
        for (auto &value: input) value=.1f*std::sin(2*M_PI*1000*position++/44100);
        bridge.push(input.data(),input.size()); bridge.render(output.data(),output.size());
        if (block>=100) {
            for (auto value: output) {
                if (previous<=0 && value>0) ++crossings;
                previous=value;
            }
        }
    }
    XCTAssertEqualWithAccuracy(double(crossings)/3,1000,3);
    XCTAssertEqual(bridge.underruns.load(),0u);
}
- (void)testFiveMinuteClockDriftRemainsBounded {
    for (bool clockAvailable: {true,false}) {
    for (double ppm: {-1000.0,1000.0}) {
        hearing::StreamBridge bridge; bridge.prepare(44100,48000,441,480);
        std::vector<float> input(441,.1f), output(480);
        double nextInput=0, nextOutput=0;
        const double inputPeriod=.01/(1+ppm/1e6);
        while (nextOutput<300) {
            if (nextInput<=nextOutput) {
                bridge.push(input.data(),input.size()); nextInput+=inputPeriod;
            } else {
                bridge.render(output.data(),output.size(),clockAvailable ? 1+ppm/1e6 : 1); nextOutput+=.01;
            }
        }
        XCTAssertLessThan(bridge.queueMS.load(),70);
        XCTAssertLessThanOrEqual(bridge.underruns.load(),2u);
        XCTAssertEqual(bridge.overflows.load(),0u);
    }
    }
}
- (void)testUnderflowAndOverflowRecoverWithoutOldBacklog {
    hearing::StreamBridge bridge; bridge.prepare(48000,48000,480,480);
    std::vector<float> large(48000,.1f), output(480);
    bridge.push(large.data(),large.size());
    XCTAssertGreaterThan(bridge.overflows.load(),0u);
    bridge.render(output.data(),output.size());
    XCTAssertLessThan(bridge.queueMS.load(),30);
    for (int i=0;i<20;++i) bridge.render(output.data(),output.size());
    XCTAssertGreaterThan(bridge.underruns.load(),0u);
    for (int i=0;i<10;++i) {
        bridge.push(large.data(),480); bridge.render(output.data(),480);
    }
    XCTAssertGreaterThan(output[300],.05f);
}
- (void)testConcurrentProducerConsumer {
    hearing::StreamBridge bridge; bridge.prepare(48000,48000,128,128);
    std::atomic<bool> complete{false}, finite{true};
    std::thread producer([&] {
        float input[128]; std::fill_n(input,128,.05f);
        for (int i=0;i<30000;++i) {
            bridge.push(input,128);
            if (i%32==0) std::this_thread::yield();
        }
        complete.store(true);
    });
    std::thread consumer([&] {
        float output[128];
        while (!complete.load()) {
            bridge.render(output,128);
            for (auto sample: output) if (!std::isfinite(sample)) finite.store(false);
        }
    });
    producer.join(); consumer.join();
    XCTAssertTrue(finite.load());
}
- (void)testEngineStartsMutedAndInvalidDevicesFailSafely {
    auto *engine=HearingCreate();
    XCTAssertNotEqual(HearingStart(engine,0,0),0);
    const auto snapshot=HearingReadSnapshot(engine);
    XCTAssertEqual(snapshot.running,0);
    HearingStop(engine); HearingStop(engine);
    HearingDestroy(engine);
}
@end
