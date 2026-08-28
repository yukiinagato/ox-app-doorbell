#import "DBTexts.h"

@implementation DBTexts {
  NSDictionary *_config;
  NSDictionary *_overrides;  // i18n_overrides[lang]
  NSDictionary *_builtin;    // 現在言語の組込辞書
}

@synthesize lang = _lang;

// 組込文言 (プレースホルダは {name} 形式で出現順)。ja を基底に en/zh を補う。
+ (NSDictionary *)builtinFor:(NSString *)lang {
  static NSDictionary *ja = nil;
  static NSDictionary *en = nil;
  static NSDictionary *zh = nil;
  if (ja == nil) {
    ja = [[NSDictionary alloc] initWithObjectsAndKeys:
      @"{door}を呼び出す", @"idle.call_button",
      @"画面にタッチで呼び出し", @"idle.touch_to_call",
      @"ご用件を選んでください", @"idle.choose_purpose",
      @"呼び出し中…", @"calling.title",
      @"取消", @"calling.cancel",
      @"応答がありませんでした", @"calling.no_answer",
      @"応対メッセージ", @"reply.banner",
      @"返信を選んでください", @"reply.choose",
      @"「{msg}」を送信しました", @"reply.sent",
      @"接続できません", @"offline.title",
      @"ネットワークを確認してください", @"offline.body",
      @"SOS", @"emergency.button",
      @"{sec}秒長押しで通報", @"emergency.hold_hint",
      @"緊急通報中", @"emergency.title",
      @"全ノードへ通報しました", @"emergency.notified",
      @"解除", @"emergency.cancel",
      @"通話中", @"incall.title",
      @"終了", @"incall.end",
      @"{door} 来客", @"ring.incoming",
      @"映像なし", @"ring.no_video",
      @"応答", @"ring.answer",
      @"聞く", @"ring.monitor",
      @"無視", @"ring.ignore",
      @"門口の音声を聞いています", @"ring.monitoring",
      @"用件: {label}", @"ring.purpose_badge",
      @"訪客言語: {lang}", @"ring.lang_badge",
      @"開錠", @"ring.open_door",
      @"「{label}」で呼び出しました", @"purpose.sent",
      @"管理", @"admin.title",
      @"PIN を入力", @"admin.pin_prompt",
      @"PIN が違います", @"admin.pin_wrong",
      @"ロック中です。しばらく待ってください", @"admin.locked",
      nil];
    en = [[NSDictionary alloc] initWithObjectsAndKeys:
      @"Call {door}", @"idle.call_button",
      @"Touch to call", @"idle.touch_to_call",
      @"Select your purpose", @"idle.choose_purpose",
      @"Calling…", @"calling.title",
      @"Cancel", @"calling.cancel",
      @"No answer", @"calling.no_answer",
      @"Message", @"reply.banner",
      @"Choose a reply", @"reply.choose",
      @"Sent: {msg}", @"reply.sent",
      @"Offline", @"offline.title",
      @"Check the network", @"offline.body",
      @"SOS", @"emergency.button",
      @"Hold {sec}s to alert", @"emergency.hold_hint",
      @"EMERGENCY", @"emergency.title",
      @"All nodes notified", @"emergency.notified",
      @"Cancel", @"emergency.cancel",
      @"In call", @"incall.title",
      @"End", @"incall.end",
      @"{door} visitor", @"ring.incoming",
      @"No video", @"ring.no_video",
      @"Answer", @"ring.answer",
      @"Listen", @"ring.monitor",
      @"Ignore", @"ring.ignore",
      @"Listening to the door", @"ring.monitoring",
      @"Purpose: {label}", @"ring.purpose_badge",
      @"Visitor language: {lang}", @"ring.lang_badge",
      @"Unlock", @"ring.open_door",
      @"Called with {label}", @"purpose.sent",
      @"Admin", @"admin.title",
      @"Enter PIN", @"admin.pin_prompt",
      @"Wrong PIN", @"admin.pin_wrong",
      @"Locked. Please wait.", @"admin.locked",
      nil];
    zh = [[NSDictionary alloc] initWithObjectsAndKeys:
      @"呼叫{door}", @"idle.call_button",
      @"触摸屏幕呼叫", @"idle.touch_to_call",
      @"请选择来访事由", @"idle.choose_purpose",
      @"呼叫中…", @"calling.title",
      @"取消", @"calling.cancel",
      @"无人应答", @"calling.no_answer",
      @"应答消息", @"reply.banner",
      @"请选择回复", @"reply.choose",
      @"已发送：{msg}", @"reply.sent",
      @"无法连接", @"offline.title",
      @"请检查网络", @"offline.body",
      @"SOS", @"emergency.button",
      @"长按{sec}秒报警", @"emergency.hold_hint",
      @"紧急报警中", @"emergency.title",
      @"已通知全部节点", @"emergency.notified",
      @"解除", @"emergency.cancel",
      @"通话中", @"incall.title",
      @"结束", @"incall.end",
      @"{door} 来访", @"ring.incoming",
      @"无视频", @"ring.no_video",
      @"应答", @"ring.answer",
      @"监听", @"ring.monitor",
      @"忽略", @"ring.ignore",
      @"正在监听门口", @"ring.monitoring",
      @"事由：{label}", @"ring.purpose_badge",
      @"访客语言：{lang}", @"ring.lang_badge",
      @"开锁", @"ring.open_door",
      @"已以「{label}」呼叫", @"purpose.sent",
      @"管理", @"admin.title",
      @"输入 PIN", @"admin.pin_prompt",
      @"PIN 错误", @"admin.pin_wrong",
      @"已锁定，请稍候", @"admin.locked",
      nil];
  }
  if ([lang isEqualToString:@"en"]) return en;
  if ([lang isEqualToString:@"zh"]) return zh;
  return ja;
}

- (id)init {
  self = [super init];
  if (self) {
    _lang = [@"ja" copy];
    [self reload];
  }
  return self;
}

- (void)dealloc {
  [_lang release];
  [_config release];
  [_overrides release];
  [_builtin release];
  [super dealloc];
}

- (void)setConfig:(NSDictionary *)cfg {
  [cfg retain];
  [_config release];
  _config = cfg;
  [self reload];
}

- (void)setLang:(NSString *)lang {
  NSString *l = [lang length] == 0 ? @"ja" : lang;
  [l retain];
  [_lang release];
  _lang = l;
  [self reload];
}

- (void)reload {
  id ov = [_config objectForKey:@"i18n_overrides"];
  id langOv = [ov isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)ov objectForKey:_lang] : nil;
  NSDictionary *newOv = [langOv isKindOfClass:[NSDictionary class]] ? langOv : nil;
  [newOv retain];
  [_overrides release];
  _overrides = newOv;
  NSDictionary *b = [[[self class] builtinFor:_lang] retain];
  [_builtin release];
  _builtin = b;
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
