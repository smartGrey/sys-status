#import "HeaderSession.h"
#import <CFNetwork/CFNetwork.h>
#import <curl/curl.h>

// URLSession may wait for the first body byte before delivering HTTP/1 response
// headers. libcurl's header callback also fires when the body stalls indefinitely.
typedef struct {
    CURL *easy;
    long status;
    BOOL transferEncoded;
} HeaderResult;

static size_t receiveHeader(char *line, size_t size, size_t count, void *context) {
    size_t length = size * count;
    HeaderResult *result = context;
    if (length != 2 || memcmp(line, "\r\n", 2) != 0) {
        if (length >= 5 && strncasecmp(line, "HTTP/", 5) == 0) result->transferEncoded = NO;
        if (length >= 18 && strncasecmp(line, "Transfer-Encoding:", 18) == 0) result->transferEncoded = YES;
        return length;
    }
    long status = 0;
    curl_easy_getinfo(result->easy, CURLINFO_RESPONSE_CODE, &status);
    if (status < 200 && status != 101) return length;
    result->status = status;
    curl_off_t bodyLength = -1;
    curl_easy_getinfo(result->easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &bodyLength);
    // Let bodyless responses finish normally, preserving the connection for a daily probe.
    return status == 204 || status == 304 || (status != 101 && !result->transferEncoded && bodyLength == 0) ? length : 0;
}

static size_t stopBody(char *data, size_t size, size_t count, void *context) { return 0; }

@interface HeaderTask ()
@property (atomic) BOOL cancelled;
@property (nonatomic) CURLM *transfer;
@end

@implementation HeaderTask
- (void)cancel {
    @synchronized (self) {
        self.cancelled = YES;
        if (_transfer) curl_multi_wakeup(_transfer);
    }
}
@end

// Keep each multi handle's connection cache when it becomes idle. A fresh probe
// owns its own session. Overlapping daily probes can check out separate handles.
@implementation HeaderSession {
    NSMutableArray<NSValue *> *_idle;
}

- (instancetype)init {
    if ((self = [super init])) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ curl_global_init(CURL_GLOBAL_DEFAULT); });
        _idle = [NSMutableArray array];
    }
    return self;
}

- (CURLM *)takeConnection {
    @synchronized (_idle) {
        NSValue *last = _idle.lastObject;
        if (!last) return curl_multi_init();
        [_idle removeLastObject];
        return last.pointerValue;
    }
}

- (void)dealloc {
    for (NSValue *value in _idle) curl_multi_cleanup(value.pointerValue);
}

static void receiveProxyList(void *context, CFArrayRef proxies, CFErrorRef error) {
    NSMutableArray *result = (__bridge NSMutableArray *)context;
    if (proxies) [result addObjectsFromArray:(__bridge NSArray *)proxies];
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static NSArray *systemProxies(NSURL *url, HeaderTask *task, NSTimeInterval deadline) {
    NSDictionary *settings = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    if (!settings) return @[];
    NSArray *options = CFBridgingRelease(CFNetworkCopyProxiesForURL((__bridge CFURLRef)url,
                                                                     (__bridge CFDictionaryRef)settings));
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *option in options) {
        id type = option[(__bridge id)kCFProxyTypeKey];
        CFStreamClientContext context = {0, (__bridge void *)result, NULL, NULL, NULL};
        CFRunLoopSourceRef source;
        if ([type isEqual:(__bridge id)kCFProxyTypeAutoConfigurationURL]) {
            NSURL *pac = option[(__bridge id)kCFProxyAutoConfigurationURLKey];
            source = CFNetworkExecuteProxyAutoConfigurationURL((__bridge CFURLRef)pac, (__bridge CFURLRef)url,
                                                               receiveProxyList, &context);
        } else if ([type isEqual:(__bridge id)kCFProxyTypeAutoConfigurationJavaScript]) {
            NSString *script = option[(__bridge id)kCFProxyAutoConfigurationJavaScriptKey];
            source = CFNetworkExecuteProxyAutoConfigurationScript((__bridge CFStringRef)script, (__bridge CFURLRef)url,
                                                                  receiveProxyList, &context);
        } else {
            [result addObject:option];
            continue;
        }
        if (!source) continue;
        CFStringRef mode = CFSTR("NetRate.ProxyResolution");
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, mode);
        while (!task.cancelled && NSProcessInfo.processInfo.systemUptime < deadline) {
            if (CFRunLoopRunInMode(mode, 0.1, false) != kCFRunLoopRunTimedOut) break;
        }
        CFRunLoopSourceInvalidate(source);
        CFRelease(source);
    }
    return result;
}

static BOOL configureProxy(CURL *easy, NSDictionary *proxy) {
    id type = proxy[(__bridge id)kCFProxyTypeKey];
    if ([type isEqual:(__bridge id)kCFProxyTypeNone]) {
        curl_easy_setopt(easy, CURLOPT_PROXY, "");
        return YES;
    }
    BOOL socks = [type isEqual:(__bridge id)kCFProxyTypeSOCKS];
    if (!socks && ![type isEqual:(__bridge id)kCFProxyTypeHTTP] && ![type isEqual:(__bridge id)kCFProxyTypeHTTPS]) return NO;
    NSString *host = proxy[(__bridge id)kCFProxyHostNameKey];
    NSNumber *port = proxy[(__bridge id)kCFProxyPortNumberKey];
    if (!host.length || !port) return NO;
    curl_easy_setopt(easy, CURLOPT_NOPROXY, "");
    curl_easy_setopt(easy, CURLOPT_PROXYTYPE, socks ? (long)CURLPROXY_SOCKS5_HOSTNAME : (long)CURLPROXY_HTTP);
    curl_easy_setopt(easy, CURLOPT_PROXY, host.UTF8String);
    curl_easy_setopt(easy, CURLOPT_PROXYPORT, port.longValue);
    NSString *user = proxy[(__bridge id)kCFProxyUsernameKey];
    NSString *password = proxy[(__bridge id)kCFProxyPasswordKey];
    if (user) {
        curl_easy_setopt(easy, CURLOPT_PROXYUSERNAME, user.UTF8String);
        curl_easy_setopt(easy, CURLOPT_PROXYPASSWORD, password.UTF8String);
        curl_easy_setopt(easy, CURLOPT_PROXYAUTH, CURLAUTH_ANY);
    }
    return YES;
}

static CURLcode perform(CURLM *multi, CURL *easy, HeaderTask *task) {
    if (curl_multi_add_handle(multi, easy) != CURLM_OK) return CURLE_FAILED_INIT;
    CURLcode result = CURLE_ABORTED_BY_CALLBACK;
    while (!task.cancelled) {
        int running = 0;
        if (curl_multi_perform(multi, &running) != CURLM_OK) break;
        if (!running) {
            int remaining;
            CURLMsg *message = curl_multi_info_read(multi, &remaining);
            if (message && message->msg == CURLMSG_DONE) result = message->data.result;
            break;
        }
        if (curl_multi_poll(multi, NULL, 0, 1000, NULL) != CURLM_OK) break;
    }
    curl_multi_remove_handle(multi, easy);
    return result;
}

- (HeaderTask *)get:(NSURL *)url timeout:(NSTimeInterval)timeout
         completion:(void (^)(NSInteger, BOOL, BOOL))completion {
    HeaderTask *task = [HeaderTask new];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSArray *proxies = systemProxies(url, task, deadline);
            CURLM *multi = [self takeConnection];
            @synchronized (task) { task.transfer = multi; }
            long status = 0;
            BOOL reused = NO, timedOut = NO;
            for (NSDictionary *proxy in proxies) {
                double left = deadline - NSProcessInfo.processInfo.systemUptime;
                if (!multi || task.cancelled || left <= 0) break;
                CURL *easy = curl_easy_init();
                if (!easy) break;
                if (!configureProxy(easy, proxy)) { curl_easy_cleanup(easy); continue; }
                HeaderResult result = {.easy = easy};
                curl_easy_setopt(easy, CURLOPT_URL, url.absoluteString.UTF8String);
                curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
                // The monitor also owns a monotonic deadline, including time spent resolving PAC.
                long milliseconds = left < (double)LONG_MAX / 1000.0 ? (long)ceil(left * 1000) : LONG_MAX;
                curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, milliseconds);
                curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, milliseconds);
                curl_easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
                curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, receiveHeader);
                curl_easy_setopt(easy, CURLOPT_HEADERDATA, &result);
                curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, stopBody);
                CURLcode code = perform(multi, easy, task);
                long connections = 0;
                curl_easy_getinfo(easy, CURLINFO_NUM_CONNECTS, &connections);
                status = result.status;
                long requestBytes = 0;
                curl_easy_getinfo(easy, CURLINFO_REQUEST_SIZE, &requestBytes);
                reused = connections == 0 && (status != 0 || requestBytes > 0);
                timedOut = code == CURLE_OPERATION_TIMEDOUT;
                curl_easy_cleanup(easy);
                // Only try the next system route when no request reached the origin.
                if (code != CURLE_COULDNT_CONNECT && code != CURLE_COULDNT_RESOLVE_PROXY) break;
            }
            @synchronized (task) { task.transfer = NULL; }
            if (multi) {
                @synchronized (self->_idle) { [self->_idle addObject:[NSValue valueWithPointer:multi]]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(status, reused, timedOut); });
        }
    });
    return task;
}
@end
