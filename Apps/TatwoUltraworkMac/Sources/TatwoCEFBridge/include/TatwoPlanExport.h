#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface TatwoPlanExport : NSObject
+ (nullable NSString *)writeData:(NSData *)data directory:(NSString *)directory
    name:(NSString *)name error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
