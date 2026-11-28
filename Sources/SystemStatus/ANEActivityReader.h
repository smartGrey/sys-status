#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owned and sampled serially by SystemResourceReader.
@interface ANEActivityReader : NSObject
+ (nullable instancetype)openReader NS_SWIFT_NAME(open());
- (nullable NSNumber *)samplePercent;
@end

NS_ASSUME_NONNULL_END
