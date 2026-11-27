#include "DSP.hpp"
#include <cstdio>
#include <sys/resource.h>

int main() {
    hearing::StreamBridge bridge;
    bridge.prepare(44100,48000,441,480);
    std::vector<float> input(441,.05f), output(480);
    double inputTime=0, outputTime=0;
    float maxQueue=0;
    // Eight hours of audio, accelerated, with changing unsignalled device drift.
    while (outputTime<8*3600) {
        if (inputTime<=outputTime) {
            bridge.push(input.data(),input.size());
            const double ppm=600*std::sin(inputTime/1800);
            inputTime+=.01/(1+ppm/1e6);
        } else {
            bridge.render(output.data(),output.size());
            outputTime+=.01;
            maxQueue=std::max(maxQueue,bridge.queueMS.load());
        }
    }
    rusage usage{}; getrusage(RUSAGE_SELF,&usage);
    std::printf("{\"simulatedHours\":8,\"maxQueueMs\":%.3f,\"finalQueueMs\":%.3f,"
                "\"underruns\":%llu,\"overflows\":%llu,\"peakResidentBytes\":%ld}\n",
                maxQueue,bridge.queueMS.load(),bridge.underruns.load(),bridge.overflows.load(),usage.ru_maxrss);
    return bridge.underruns.load()>2 || bridge.overflows.load()>0 || maxQueue>70 ? 1 : 0;
}
