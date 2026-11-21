#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A session owns reusable connections. Each task completes on the main queue after
// its transfer has released its slot, including when explicitly cancelled.
@interface HeaderTask : NSObject
- (void)cancel;
@end

@interface HeaderSession : NSObject
- (HeaderTask *)get:(NSURL *)url timeout:(NSTimeInterval)timeout
         completion:(void (^)(NSInteger status, BOOL reused, BOOL timedOut))completion;
@end

NS_ASSUME_NONNULL_END
