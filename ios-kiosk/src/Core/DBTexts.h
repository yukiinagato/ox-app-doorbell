#import <Foundation/Foundation.h>

// 文言 (組込 ja/en/zh + config i18n_overrides[lang] で上書き)。
// プレースホルダは {name} 形式で出現順に置換。
@interface DBTexts : NSObject

@property(nonatomic, readonly, copy) NSString *lang;

- (void)setConfig:(NSDictionary *)cfg;  // config_changed で差し替え
- (void)setLang:(NSString *)lang;

- (NSString *)ts:(NSString *)key;                       // 無引数
- (NSString *)t:(NSString *)key, ... NS_REQUIRES_NIL_TERMINATION;  // {name} 置換

+ (NSString *)langDisplayName:(NSString *)lang;

@end
