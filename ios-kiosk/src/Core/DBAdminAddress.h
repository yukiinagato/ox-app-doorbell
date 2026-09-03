#import <Foundation/Foundation.h>

// The admin address as shown under the QR block, in the forms it may be
// shortened to when the footer row is too narrow for all of it.
//
// The host and port are the part a person has to read off the screen and type
// into a browser; the path and the scheme are not. So the path is dropped
// first and the scheme second, and only a width too narrow for the host itself
// can ever truncate inside it.
@interface DBAdminAddress : NSObject

// Longest first: the whole URL, then without the scheme, then host and port
// alone. Never empty for a non-empty URL, and never contains duplicates.
+ (NSArray *)formsForUrl:(NSString *)url;

@end
