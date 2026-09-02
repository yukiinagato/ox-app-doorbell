#import <Foundation/Foundation.h>

// Generated ja/en/zh defaults with config i18n_overrides[lang] applied on top.
// Named placeholders are replaced positionally in their order of appearance.
@interface DBTexts : NSObject

@property(nonatomic, readonly, copy) NSString *lang;

- (void)setConfig:(NSDictionary *)cfg;
- (void)setLang:(NSString *)lang;

- (NSString *)ts:(NSString *)key;
- (NSString *)t:(NSString *)key, ... NS_REQUIRES_NIL_TERMINATION;

+ (NSString *)langDisplayName:(NSString *)lang;

@end
