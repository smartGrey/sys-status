#include "Environment.hpp"
#include "DSP.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <sys/resource.h>

static thread_local bool processing = false;
static size_t realtimeAllocations = 0;
void* operator new(size_t n) {
    if (processing) ++realtimeAllocations;
    if (void* p=std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }

int main() {
    hearing::EnvironmentProcessor environment; environment.prepare(48000,true);
    hearing::Gate gate; gate.prepare(48000); gate.setParameters({9,24,1});
    hearing::StreamBridge bridge; bridge.prepare(48000,48000,480,480);
    std::array<float,480> input{}, output{};
    std::array<size_t,1001> durationHistogram{};
    uint32_t random=1; uint64_t frames=0;
    double totalMS=0,maximumMS=0; float peak=0; bool finite=true;
    constexpr int blocks=180000; // Thirty minutes of the complete DSP chain.
    for(int block=0;block<blocks;++block) {
        for(auto& x: input) {
            const double t=double(frames++)/48000;
            random=1664525*random+1013904223;
            x=.03f*std::sin(2*M_PI*80*t)+.002f*float(int32_t(random))/2147483648.f;
            if(block%3000<600) x+=.02f*std::sin(2*M_PI*1400*t);
            if(block%12000>6000) x*=3;
        }
        if(block%10000==0) environment.setReduction(block%30000 == 0 ? 0 : block%30000 == 10000 ? 18 : 30);
        const auto start=std::chrono::steady_clock::now(); processing=true;
        for(auto& x:input) x=gate.process(environment.process(x),environment.scoreDB(),environment.ready());
        bridge.push(input.data(),input.size()); bridge.render(output.data(),output.size());
        processing=false;
        const double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        totalMS+=ms; maximumMS=std::max(maximumMS,ms);
        ++durationHistogram[std::min<size_t>(1000,size_t(ms/.01))];
        for(auto x:output) { finite &= std::isfinite(x); peak=std::max(peak,std::abs(x)); }
    }
    size_t count=0,percentile=0;
    for(;percentile<durationHistogram.size();++percentile) {
        count+=durationHistogram[percentile]; if(count>=blocks*.99) break;
    }
    rusage usage{}; getrusage(RUSAGE_SELF,&usage);
    const double p99=(percentile+1)*.01;
    std::printf("{\"simulatedMinutes\":30,\"inputBlockMS\":10,\"meanProcessingMS\":%.4f,\"p99ProcessingMS\":%.3f,"
        "\"maximumProcessingMS\":%.3f,\"cppRealtimeAllocations\":%zu,\"peak\":%.6f,\"finite\":%s,"
        "\"underruns\":%llu,\"overflows\":%llu,\"peakResidentBytes\":%ld}\n",
        totalMS/blocks,p99,maximumMS,realtimeAllocations,peak,finite?"true":"false",
        bridge.underruns.load(),bridge.overflows.load(),usage.ru_maxrss);
    return !finite || realtimeAllocations || p99>=5 || peak>hearing::PeakLimiter::ceiling+1e-6f ||
        bridge.underruns.load()>2 || bridge.overflows.load()>0;
}
