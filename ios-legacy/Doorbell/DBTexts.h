// 文言解決 (ios/Doorbell/Texts.swift の MRC 移植)。iOS5 殻は .lproj バンドルの代わりに
// 組込辞書 (ja/en/zh) を持ち、config i18n_overrides.<lang>.<key> があればそれを優先する。
// プレースホルダ {name} は出現順に args で埋める。
#import <Foundation/Foundation.h>

@interface DBTexts : NSObject

@property(nonatomic, readonly, copy) NSString *lang;

- (void)setConfig:(NSDictionary *)cfg;
- (void)setLang:(NSString *)lang;

// key = ドットキー。上書き → 組込辞書の順で解決。args は nil 終端の可変長。
- (NSString *)t:(NSString *)key, ... NS_REQUIRES_NIL_TERMINATION;
// 引数無し版 (可変長の nil 忘れ回避)。
- (NSString *)ts:(NSString *)key;

+ (NSString *)langDisplayName:(NSString *)lang;

@end
