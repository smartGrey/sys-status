#import "ANEActivityReader.h"
#import <dlfcn.h>

@implementation ANEActivityReader {
    void *_library;
    CFTypeRef _subscription;
    CFMutableDictionaryRef _channels;
    CFDictionaryRef _previous;
    CFDictionaryRef (*_sample)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*_delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    int (*_format)(CFDictionaryRef);
    CFStringRef (*_channelName)(CFDictionaryRef);
    int (*_count)(CFDictionaryRef);
    CFStringRef (*_stateName)(CFDictionaryRef, int);
    uint64_t (*_residency)(CFDictionaryRef, int);
}

+ (instancetype)openReader { return [[self alloc] initWithClusterChannels]; }

- (instancetype)initWithClusterChannels {
    self = [super init];
    if (!self) return nil;
    _library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LOCAL | RTLD_LAZY);
    if (!_library) return nil;
    CFMutableDictionaryRef (*copy)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t) =
        dlsym(_library, "IOReportCopyChannelsInGroup");
    CFTypeRef (*subscribe)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef) =
        dlsym(_library, "IOReportCreateSubscription");
    _sample = dlsym(_library, "IOReportCreateSamples");
    _delta = dlsym(_library, "IOReportCreateSamplesDelta");
    _format = dlsym(_library, "IOReportChannelGetFormat");
    _channelName = dlsym(_library, "IOReportChannelGetChannelName");
    _count = dlsym(_library, "IOReportStateGetCount");
    _stateName = dlsym(_library, "IOReportStateGetNameForIndex");
    _residency = dlsym(_library, "IOReportStateGetResidency");
    if (!copy || !subscribe || !_sample || !_delta || !_format || !_channelName ||
        !_count || !_stateName || !_residency) return nil;

    NSMutableDictionary *request = CFBridgingRelease(copy(CFSTR("SoC Stats"), CFSTR("Cluster Power States"), 0, 0, 0));
    NSArray *channels = request[@"IOReportChannels"];
    if (![channels isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *neural = [NSMutableArray array];
    for (NSDictionary *channel in channels) {
        if (![channel isKindOfClass:NSDictionary.class]) continue;
        CFDictionaryRef ref = (__bridge CFDictionaryRef)channel;
        if (_format(ref) != 2) continue; // IOReport state-residency channel.
        NSString *name = (__bridge NSString *)_channelName(ref);
        NSString *unit = [name componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lastObject;
        if ([unit hasPrefix:@"ANE"] && unit.length > 3 &&
            [[unit substringFromIndex:3] rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) {
            [neural addObject:channel];
        }
    }
    if (!neural.count) return nil;
    request[@"IOReportChannels"] = neural;
    _subscription = subscribe(NULL, (__bridge CFMutableDictionaryRef)request, &_channels, 0, NULL);
    if (!_subscription || !_channels) return nil;
    return self;
}

- (NSNumber *)samplePercent {
    CFDictionaryRef next = _sample(_subscription, _channels, NULL);
    NSDictionary *delta = _previous && next ? CFBridgingRelease(_delta(_previous, next, NULL)) : nil;
    if (_previous) CFRelease(_previous);
    _previous = next;
    NSNumber *highest = nil;
    for (NSDictionary *row in delta[@"IOReportChannels"]) {
        CFDictionaryRef channel = (__bridge CFDictionaryRef)row;
        double active = 0, total = 0;
        BOOL foundActive = NO, foundIdle = NO, known = YES;
        int count = _count(channel);
        for (int i = 0; i < count; ++i) {
            NSString *state = (__bridge NSString *)_stateName(channel, i);
            double ticks = _residency(channel, i);
            if ([state isEqualToString:@"ACT"]) { active += ticks; foundActive = YES; }
            else if ([state isEqualToString:@"INACT"]) foundIdle = YES;
            else { known = NO; break; }
            total += ticks;
        }
        if (known && foundActive && foundIdle && total > 0) {
            double value = 100 * active / total;
            if (!highest || value > highest.doubleValue) highest = @(value);
        }
    }
    return highest;
}

- (void)dealloc {
    if (_previous) CFRelease(_previous);
    if (_channels) CFRelease(_channels);
    if (_subscription) CFRelease(_subscription);
    if (_library) dlclose(_library);
}
@end
