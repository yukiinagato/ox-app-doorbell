#import "DBTexts.h"

@implementation DBTexts {
  NSDictionary *_config;
  NSDictionary *_overrides;  // i18n_overrides[lang]
  NSDictionary *_builtin;    // 現在言語の組込辞書
}

@synthesize lang = _lang;

// 組込文言。ja を基底に en/zh を補う。
+ (NSDictionary *)builtinFor:(NSString *)lang {
  static NSDictionary *ja = nil;
  static NSDictionary *en = nil;
  static NSDictionary *zh = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ja = @{@"idle.call_button": @"{door}を呼び出す",
           @"idle.touch_to_call": @"画面にタッチで呼び出し",
           @"idle.choose_purpose": @"ご用件を選んでください",
           @"calling.title": @"呼び出し中…",
           @"calling.cancel": @"取消",
           @"calling.no_answer": @"応答がありませんでした",
           @"reply.banner": @"応対メッセージ",
           @"reply.choose": @"返信を選んでください",
           @"reply.sent": @"「{msg}」を送信しました",
           @"offline.title": @"接続できません",
           @"offline.body": @"ネットワークを確認してください",
           @"emergency.button": @"SOS",
           @"emergency.hold_hint": @"{sec}秒長押しで通報",
           @"emergency.title": @"緊急通報中",
           @"emergency.notified": @"全ノードへ通報しました",
           @"emergency.cancel": @"解除",
           @"incall.title": @"通話中",
           @"incall.end": @"終了",
           @"ring.incoming": @"{door} 来客",
           @"ring.no_video": @"映像なし",
           @"ring.answer": @"応答",
           @"ring.monitor": @"聞く",
           @"ring.ignore": @"無視",
           @"ring.monitoring": @"門口の音声を聞いています",
           @"ring.purpose_badge": @"用件: {label}",
           @"ring.lang_badge": @"訪客言語: {lang}",
           @"ring.open_door": @"開錠",
           @"purpose.sent": @"「{label}」で呼び出しました",
           @"admin.title": @"管理",
           @"admin.pin_prompt": @"PIN を入力",
           @"admin.pin_wrong": @"PIN が違います",
           @"admin.locked": @"ロック中です。しばらく待ってください"};
    en = @{@"idle.call_button": @"Call {door}",
           @"idle.touch_to_call": @"Touch to call",
           @"idle.choose_purpose": @"Select your purpose",
           @"calling.title": @"Calling…",
           @"calling.cancel": @"Cancel",
           @"calling.no_answer": @"No answer",
           @"reply.banner": @"Message",
           @"reply.choose": @"Choose a reply",
           @"reply.sent": @"Sent: {msg}",
           @"offline.title": @"Offline",
           @"offline.body": @"Check the network",
           @"emergency.button": @"SOS",
           @"emergency.hold_hint": @"Hold {sec}s to alert",
           @"emergency.title": @"EMERGENCY",
           @"emergency.notified": @"All nodes notified",
           @"emergency.cancel": @"Cancel",
           @"incall.title": @"In call",
           @"incall.end": @"End",
           @"ring.incoming": @"{door} visitor",
           @"ring.no_video": @"No video",
           @"ring.answer": @"Answer",
           @"ring.monitor": @"Listen",
           @"ring.ignore": @"Ignore",
           @"ring.monitoring": @"Listening to the door",
           @"ring.purpose_badge": @"Purpose: {label}",
           @"ring.lang_badge": @"Visitor language: {lang}",
           @"ring.open_door": @"Unlock",
           @"purpose.sent": @"Called with {label}",
           @"admin.title": @"Admin",
           @"admin.pin_prompt": @"Enter PIN",
           @"admin.pin_wrong": @"Wrong PIN",
           @"admin.locked": @"Locked. Please wait."};
    zh = [self zhDict];
  });
  if ([lang isEqualToString:@"en"]) return en;
  if ([lang isEqualToString:@"zh"]) return zh;
  return ja;
}
+ (NSDictionary *)zhDict {
  return @{@"idle.call_button": @"呼叫{door}",
           @"idle.touch_to_call": @"触摸屏幕呼叫",
           @"idle.choose_purpose": @"请选择来访事由",
           @"calling.title": @"呼叫中…",
           @"calling.cancel": @"取消",
           @"calling.no_answer": @"无人应答",
           @"reply.banner": @"应答消息",
           @"reply.choose": @"请选择回复",
           @"reply.sent": @"已发送：{msg}",
           @"offline.title": @"无法连接",
           @"offline.body": @"请检查网络",
           @"emergency.button": @"SOS",
           @"emergency.hold_hint": @"长按{sec}秒报警",
           @"emergency.title": @"紧急报警中",
           @"emergency.notified": @"已通知全部节点",
           @"emergency.cancel": @"解除",
           @"incall.title": @"通话中",
           @"incall.end": @"结束",
           @"ring.incoming": @"{door} 来访",
           @"ring.no_video": @"无视频",
           @"ring.answer": @"应答",
           @"ring.monitor": @"监听",
           @"ring.ignore": @"忽略",
           @"ring.monitoring": @"正在监听门口",
           @"ring.purpose_badge": @"事由：{label}",
           @"ring.lang_badge": @"访客语言：{lang}",
           @"ring.open_door": @"开锁",
           @"purpose.sent": @"已以「{label}」呼叫",
           @"admin.title": @"管理",
           @"admin.pin_prompt": @"输入 PIN",
           @"admin.pin_wrong": @"PIN 错误",
           @"admin.locked": @"已锁定，请稍候"};
}

- (id)init {
  self = [super init];
  if (self) {
    _lang = @"ja";
    [self reload];
  }
  return self;
}

- (void)setConfig:(NSDictionary *)cfg {
  _config = cfg;
  [self reload];
}

- (void)setLang:(NSString *)lang {
  _lang = [lang length] == 0 ? @"ja" : lang;
  [self reload];
}

- (void)reload {
  id ov = [_config objectForKey:@"i18n_overrides"];
  id langOv = [ov isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)ov objectForKey:_lang] : nil;
  _overrides = [langOv isKindOfClass:[NSDictionary class]] ? langOv : nil;
  _builtin = [[self class] builtinFor:_lang];
}

- (NSString *)resolveFmt:(NSString *)key {
  id ov = [_overrides objectForKey:key];
  if ([ov isKindOfClass:[NSString class]] && [(NSString *)ov length] > 0) return ov;
  NSString *b = [_builtin objectForKey:key];
  return b ? b : key;
}

- (NSString *)fill:(NSString *)fmt args:(NSArray *)args {
  if ([args count] == 0) return fmt;
  NSMutableString *out = [NSMutableString stringWithString:fmt];
  NSError *err = nil;
  NSRegularExpression *re =
      [NSRegularExpression regularExpressionWithPattern:@"\\{[A-Za-z_][A-Za-z0-9_]*\\}"
                                                options:0
                                                  error:&err];
  if (re == nil) return fmt;
  NSUInteger i = 0;
  while (i < [args count]) {
    NSTextCheckingResult *m =
        [re firstMatchInString:out options:0 range:NSMakeRange(0, [out length])];
    if (m == nil) break;
    [out replaceCharactersInRange:m.range withString:[args objectAtIndex:i]];
    i++;
  }
  return out;
}

- (NSString *)ts:(NSString *)key {
  return [self resolveFmt:key];
}

- (NSString *)t:(NSString *)key, ... {
  NSString *fmt = [self resolveFmt:key];
  NSMutableArray *args = [NSMutableArray array];
  va_list ap;
  va_start(ap, key);
  id a;
  while ((a = va_arg(ap, id)) != nil) {
    [args addObject:[a isKindOfClass:[NSString class]] ? a : [NSString stringWithFormat:@"%@", a]];
  }
  va_end(ap);
  return [self fill:fmt args:args];
}

+ (NSString *)langDisplayName:(NSString *)lang {
  if ([lang isEqualToString:@"ja"]) return @"日本語";
  if ([lang isEqualToString:@"en"]) return @"English";
  if ([lang isEqualToString:@"zh"]) return @"中文";
  return lang;
}

@end

