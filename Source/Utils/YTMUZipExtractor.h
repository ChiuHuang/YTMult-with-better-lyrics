#import <Foundation/Foundation.h>

@interface YTMUZipExtractor : NSObject
+ (BOOL)unzipFileAtPath:(NSString *)zipPath toDestination:(NSString *)destDir error:(NSError **)outError;
@end
