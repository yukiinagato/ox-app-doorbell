#import "DBSettingsPages.h"

#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>

#import "../Core/DBAdminHttpSession.h"
#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBGeneratedStrings.h"
#import "../Core/DBTexts.h"
#import "../Media/DBQrCode.h"
#import "DBEditor.h"
#import "DBRouter.h"

static NSArray *kDBLangs(void) { return @[ @"ja", @"en", @"zh" ]; }

static NSString *DBRandomHex(NSUInteger bytes) {
  NSMutableData *data = [NSMutableData dataWithLength:bytes];
  if (SecRandomCopyBytes(kSecRandomDefault, bytes, (uint8_t *)[data mutableBytes]) != 0) return nil;
  NSMutableString *hex = [NSMutableString stringWithCapacity:bytes * 2];
  const uint8_t *p = (const uint8_t *)[data bytes];
  for (NSUInteger i = 0; i < bytes; i++) [hex appendFormat:@"%02x", p[i]];
  return hex;
}

static NSString *DBJsonFragment(id value) {
  if (value == nil) return nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ] options:0 error:NULL];
  if (data == nil) return nil;
  NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return [array length] >= 2 ? [array substringWithRange:NSMakeRange(1, [array length] - 2)] : nil;
}

static NSDictionary *DBDict(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static NSArray *DBArray(id value) {
  return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static NSString *DBTrim(NSString *text) {
  return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// The {name} placeholders a wording override must keep.
static NSSet *DBPlaceholders(NSString *text) {
  NSMutableSet *names = [NSMutableSet set];
  NSRegularExpression *pattern =
      [NSRegularExpression regularExpressionWithPattern:@"\\{[A-Za-z0-9_]+\\}" options:0 error:NULL];
  for (NSTextCheckingResult *match in
       [pattern matchesInString:text ?: @"" options:0 range:NSMakeRange(0, [text length])])
    [names addObject:[text substringWithRange:match.range]];
  return names;
}

// Keys whose path segments are configuration identifiers must not carry dots.
static BOOL DBSafeId(NSString *identifier) {
  if ([identifier length] == 0 || [identifier length] > 64) return NO;
  NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
  return [identifier rangeOfCharacterFromSet:bad].location == NSNotFound;
}

@interface DBSettingsPages () <UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                               AVAudioRecorderDelegate, UIPopoverControllerDelegate>
@end

@implementation DBSettingsPages {
  __weak DBRouter *_router;
  __weak DBEditorView *_editor;
  DBCoreBridge *_core;
  DBTexts *_texts;
  DBBootConfig *_boot;
  NSDictionary *_cfg;
  DBAdminHttpSession *_http;
  UIPopoverController *_popover;
  UIImagePickerController *_picker;
  NSString *_pickerScope;
  AVAudioRecorder *_recorder;
  NSString *_recordPath;
  NSString *_recordLabel;
  NSString *_savedAudioCategory;
}
@synthesize nodeId = _nodeId;

- (id)initWithRouter:(DBRouter *)router editor:(DBEditorView *)editor nodeId:(NSString *)nodeId {
  self = [super init];
  if (self) {
    _router = router;
    _editor = editor;
    _core = router.core;
    _texts = router.texts;
    _boot = router.boot;
    _nodeId = [nodeId copy] ?: @"";
  }
  return self;
}

- (void)close {
  _http = nil;
  [_recorder stop];
  _recorder = nil;
}

- (NSString *)t:(NSString *)key {
  return [_texts ts:key];
}

- (NSString *)lang {
  return [_boot.uiLang length] > 0 ? _boot.uiLang : @"ja";
}

#pragma mark - configuration

- (NSDictionary *)cfg {
  NSDictionary *fresh = [_core config];
  if ([fresh isKindOfClass:[NSDictionary class]]) _cfg = fresh;
  return _cfg ?: @{};
}

- (id)at:(NSString *)path {
  return [DBConfigUtil dig:[self cfg] path:path];
}

- (void)toast:(NSString *)key {
  [_editor showMessage:[self t:key]];
}

// One atomic batch. ops are {op,key,value}. A closed admin window asks for the
// password once and retries the same batch.
- (BOOL)commit:(NSArray *)ops {
  if ([ops count] == 0) return YES;
  NSDictionary *result = [_core writeConfigBatch:ops];
  if (result == nil) {
    // An older Core without the batch export: apply one key at a time.
    for (NSDictionary *op in ops) {
      NSString *key = [op objectForKey:@"key"];
      int status = [[op objectForKey:@"op"] isEqual:@"delete"]
          ? [_core deleteConfigKey:key]
          : [_core setConfigKey:key valueJson:DBJsonFragment([op objectForKey:@"value"])];
      if (status == DBAdminRequiredResult) return [self retryAfterUnlock:ops];
      if (status != 0) {
        [self toast:@"settings.save_failed"];
        return NO;
      }
    }
    [self toast:@"settings.saved"];
    return YES;
  }
  if ([[result objectForKey:@"ok"] boolValue]) {
    [self toast:@"settings.saved"];
    return YES;
  }
  NSString *err = [DBConfigUtil evStr:result key:@"err"];
  if ([err isEqualToString:@"admin_required"] ||
      [[DBConfigUtil evStr:result key:@"error_code"] isEqualToString:@"admin_required"])
    return [self retryAfterUnlock:ops];
  [_editor showMessage:[NSString stringWithFormat:@"%@\n%@", [self t:@"settings.save_failed"],
                                                  err ?: @""]];
  return NO;
}

- (BOOL)retryAfterUnlock:(NSArray *)ops {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  [_router requestPinThen:^{
    DBSettingsPages *pages = weakSelf;
    if (pages && [pages commit:ops]) [editor reloadPage];
  }];
  return NO;
}

- (NSDictionary *)set:(NSString *)key value:(id)value {
  return @{ @"op" : @"set", @"key" : key, @"value" : value ?: [NSNull null] };
}

- (NSDictionary *)del:(NSString *)key {
  return @{ @"op" : @"delete", @"key" : key };
}

- (BOOL)setKey:(NSString *)key value:(id)value {
  return [self commit:@[ [self set:key value:value] ]];
}

- (BOOL)deleteKey:(NSString *)key {
  return [self commit:@[ [self del:key] ]];
}

// Empty text clears the key rather than storing an empty string.
- (BOOL)setText:(NSString *)key value:(id)value {
  NSString *text = DBTrim([value description] ?: @"");
  return [text length] == 0 ? [self deleteKey:key] : [self setKey:key value:text];
}

// Store a secret in this device's Keychain under a fresh reference, then
// write the reference. The old secret is left for the referencing nodes that
// still hold it, matching the web admin's rotation.
- (BOOL)storeSecret:(NSString *)value base:(NSString *)base key:(NSString *)key {
  NSString *secret = value ?: @"";
  if ([secret length] == 0) return [self deleteKey:key];
  NSString *suffix = DBRandomHex(4);
  if ([suffix length] == 0) return NO;
  NSString *name = [NSString stringWithFormat:@"%@.%@", base, suffix];
  if (![_core storeSecret:name value:secret]) {
    [self toast:@"editor.secret_store_failed"];
    return NO;
  }
  return [self setKey:key value:[@"secret:" stringByAppendingString:name]];
}

- (BOOL)hasSecretAt:(NSString *)key {
  NSString *ref = [DBConfigUtil str:[self cfg] path:key];
  return [ref hasPrefix:@"secret:"];
}

#pragma mark - field helpers

- (DBEditField *)text:(NSString *)title key:(NSString *)key {
  DBEditField *field = [DBEditField kind:DBEditKindText title:title
                                   value:[DBConfigUtil str:[self cfg] path:key] ?: @""];
  __weak DBSettingsPages *weakSelf = self;
  field.onChange = ^BOOL(id value) { return [weakSelf setText:key value:value]; };
  return field;
}

- (DBEditField *)number:(NSString *)title key:(NSString *)key def:(NSInteger)def
                    min:(NSInteger)min max:(NSInteger)max {
  DBEditField *field = [DBEditField kind:DBEditKindNumber title:title
      value:[NSNumber numberWithInteger:[DBConfigUtil intVal:[self cfg] path:key def:def]]];
  field.minimum = min;
  field.maximum = max;
  __weak DBSettingsPages *weakSelf = self;
  field.onChange = ^BOOL(id value) { return [weakSelf setKey:key value:value]; };
  return field;
}

- (DBEditField *)toggle:(NSString *)title key:(NSString *)key def:(BOOL)def {
  DBEditField *field = [DBEditField kind:DBEditKindBool title:title
      value:[NSNumber numberWithBool:[DBConfigUtil boolVal:[self cfg] path:key def:def]]];
  __weak DBSettingsPages *weakSelf = self;
  field.onChange = ^BOOL(id value) { return [weakSelf setKey:key value:value]; };
  return field;
}

- (DBEditField *)choice:(NSString *)title key:(NSString *)key def:(NSString *)def
                choices:(NSArray *)choices {
  DBEditField *field = [DBEditField kind:DBEditKindChoice title:title
                                   value:[DBConfigUtil str:[self cfg] path:key] ?: def];
  field.choices = choices;
  __weak DBSettingsPages *weakSelf = self;
  field.onChange = ^BOOL(id value) { return [weakSelf setKey:key value:value]; };
  return field;
}

- (DBEditField *)secret:(NSString *)title key:(NSString *)key base:(NSString *)base {
  DBEditField *field = [DBEditField kind:DBEditKindSecret title:title
                                   value:[NSNumber numberWithBool:[self hasSecretAt:key]]];
  __weak DBSettingsPages *weakSelf = self;
  field.onChange = ^BOOL(id value) {
    return [weakSelf storeSecret:[value description] base:base key:key];
  };
  return field;
}

- (DBEditField *)page:(NSString *)title detail:(NSString *)detail
                build:(DBEditPage *(^)(void))build {
  DBEditField *field = [DBEditField kind:DBEditKindPage title:title value:nil];
  field.detail = detail;
  field.page = build;
  return field;
}

- (DBEditField *)action:(NSString *)title block:(void (^)(void))block {
  DBEditField *field = [DBEditField kind:DBEditKindAction title:title value:nil];
  field.action = block;
  return field;
}

- (NSString *)label:(id)entry fallback:(NSString *)fallback {
  return [DBConfigUtil labelOf:DBDict(entry) lang:[self lang] fallback:fallback];
}

// The three localized strings of one label map (ja/en/zh).
- (NSArray *)localizedFields:(NSString *)keyPrefix {
  NSMutableArray *fields = [NSMutableArray array];
  for (NSString *lang in kDBLangs()) {
    [fields addObject:[self text:[DBTexts langDisplayName:lang]
                             key:[NSString stringWithFormat:@"%@.%@", keyPrefix, lang]]];
  }
  return fields;
}

- (NSArray *)langChoices {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *lang in kDBLangs()) [choices addObject:@[ lang, [DBTexts langDisplayName:lang] ]];
  return choices;
}

- (NSArray *)doorChoices {
  NSMutableArray *choices = [NSMutableArray array];
  NSDictionary *doors = DBDict([self at:@"doors"]);
  for (NSString *door in [DBConfigUtil sortedByOrder:doors])
    [choices addObject:@[ door, [self label:[doors objectForKey:door] fallback:door] ]];
  return choices;
}

- (NSArray *)householdChoices {
  NSMutableArray *choices = [NSMutableArray array];
  NSDictionary *households = DBDict([self at:@"households"]);
  for (NSString *household in [DBConfigUtil sortedByOrder:households])
    [choices addObject:@[ household,
                          [self label:[households objectForKey:household] fallback:household] ]];
  return choices;
}

- (NSArray *)purposeChoices {
  NSMutableArray *choices = [NSMutableArray array];
  NSDictionary *purposes = DBDict([self at:@"visit_purposes"]);
  for (NSString *purpose in [DBConfigUtil sortedByOrder:purposes])
    [choices addObject:@[ purpose, [self label:[purposes objectForKey:purpose] fallback:purpose] ]];
  return choices;
}

- (NSArray *)replyChoices {
  NSMutableArray *choices = [NSMutableArray array];
  NSDictionary *replies = DBDict([self at:@"quick_replies"]);
  for (NSString *reply in [DBConfigUtil sortedByOrder:replies])
    [choices addObject:@[ reply, [self label:[replies objectForKey:reply] fallback:reply] ]];
  return choices;
}

- (NSArray *)soundChoices {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *name in @[ @"school_chime", @"ding1", @"ding2", @"classic", @"siren1" ]) {
    NSString *key = [@"prefs.sound_" stringByAppendingString:name];
    NSString *label = [self t:key];
    [choices addObject:@[ name, [label isEqualToString:key] ? name : label ]];
  }
  NSDictionary *assets = DBDict([self at:@"assets"]);
  for (NSString *hash in [[assets allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary *asset = DBDict([assets objectForKey:hash]);
    if (![[DBConfigUtil str:asset path:@"type"] hasPrefix:@"audio/"]) continue;
    NSString *label = [DBConfigUtil str:asset path:@"label"] ?: [hash substringToIndex:MIN(8u, [hash length])];
    [choices addObject:@[ [@"asset:" stringByAppendingString:hash], label ]];
  }
  return choices;
}

// Map entries ordered by "order", rewritten 1..n after a move.
- (BOOL)moveIn:(NSString *)root from:(NSInteger)from to:(NSInteger)to {
  NSMutableArray *ids = [NSMutableArray arrayWithArray:
      [DBConfigUtil sortedByOrder:DBDict([self at:root])]];
  if (from < 0 || to < 0 || from >= (NSInteger)[ids count] || to >= (NSInteger)[ids count]) return NO;
  NSString *moved = [ids objectAtIndex:(NSUInteger)from];
  [ids removeObjectAtIndex:(NSUInteger)from];
  [ids insertObject:moved atIndex:(NSUInteger)to];
  NSMutableArray *ops = [NSMutableArray array];
  for (NSUInteger i = 0; i < [ids count]; i++)
    [ops addObject:[self set:[NSString stringWithFormat:@"%@.%@.order", root, [ids objectAtIndex:i]]
                       value:[NSNumber numberWithUnsignedInteger:i + 1]]];
  return [self commit:ops];
}

- (NSInteger)nextOrderIn:(NSString *)root {
  NSInteger next = 1;
  NSDictionary *map = DBDict([self at:root]);
  for (NSString *key in map) next = MAX(next, [DBConfigUtil orderOf:key map:map] + 1);
  return next;
}

- (NSString *)newIdWithPrefix:(NSString *)prefix in:(NSString *)root {
  NSDictionary *map = DBDict([self at:root]);
  for (int attempt = 0; attempt < 8; attempt++) {
    NSString *candidate = [prefix stringByAppendingString:DBRandomHex(4) ?: @"x"];
    if ([map objectForKey:candidate] == nil) return candidate;
  }
  return [prefix stringByAppendingString:DBRandomHex(8) ?: @"y"];
}

// An array value edited as a list of strings: add, edit, delete, reorder.
- (DBEditPage *)stringListPage:(NSString *)title key:(NSString *)key max:(NSUInteger)max
                   placeholder:(NSString *)placeholder footer:(NSString *)footer {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:title build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSArray *items = DBArray([pages at:key]);
    NSMutableArray *fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < [items count]; i++) {
      NSString *item = [[items objectAtIndex:i] description];
      DBEditField *field = [DBEditField kind:DBEditKindText title:item value:item];
      field.placeholder = placeholder;
      field.keyboard = UIKeyboardTypeURL;
      field.onChange = ^BOOL(id value) {
        NSString *text = DBTrim([value description]);
        NSMutableArray *next = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
        if (i >= [next count]) return NO;
        if ([text length] == 0) [next removeObjectAtIndex:i];
        else [next replaceObjectAtIndex:i withObject:text];
        return [weakSelf setKey:key value:next];
      };
      [fields addObject:field];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = footer;
    section.onDelete = ^BOOL(NSInteger index) {
      NSMutableArray *next = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
      if (index < 0 || index >= (NSInteger)[next count]) return NO;
      [next removeObjectAtIndex:(NSUInteger)index];
      return [next count] == 0 ? [weakSelf deleteKey:key] : [weakSelf setKey:key value:next];
    };
    section.onMove = ^BOOL(NSInteger from, NSInteger to) {
      NSMutableArray *next = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
      if (from >= (NSInteger)[next count] || to >= (NSInteger)[next count]) return NO;
      id moved = [next objectAtIndex:(NSUInteger)from];
      [next removeObjectAtIndex:(NSUInteger)from];
      [next insertObject:moved atIndex:(NSUInteger)to];
      return [weakSelf setKey:key value:next];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    if ([DBArray([pages at:key]) count] >= max) {
      [editor showMessage:[NSString stringWithFormat:@"≤ %lu", (unsigned long)max]];
      return;
    }
    [editor promptTitle:title value:@"" placeholder:placeholder keyboard:UIKeyboardTypeURL
                 secure:NO then:^(NSString *text) {
      NSString *value = DBTrim(text);
      if ([value length] == 0) return;
      NSMutableArray *next = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
      [next addObject:value];
      if ([weakSelf setKey:key value:next]) [editor reloadPage];
    }];
  };
  return page;
}

#pragma mark - router

- (DBEditPage *)pageNamed:(NSString *)name {
  if ([name isEqualToString:@"quick_replies"]) return [self quickRepliesPage];
  if ([name isEqualToString:@"purposes"]) return [self purposesPage];
  if ([name isEqualToString:@"notice_presets"]) return [self noticePresetsPage];
  if ([name isEqualToString:@"quiet_hours"]) return [self quietHoursPage];
  if ([name isEqualToString:@"ntp_servers"])
    return [self stringListPage:[self t:@"time.servers"] key:@"time.ntp.servers" max:4
                    placeholder:@"ntp.nict.jp" footer:[self t:@"editor.ntp_servers_hint"]];
  if ([name isEqualToString:@"rules"]) return [self rulesPage];
  if ([name isEqualToString:@"telegram"]) return [self telegramPage];
  if ([name isEqualToString:@"secrets"]) return [self secretsPage];
  if ([name isEqualToString:@"sip"]) return [self sipPage];
  if ([name isEqualToString:@"mqtt"]) return [self mqttPage];
  if ([name isEqualToString:@"panels"]) return [self panelsPage];
  if ([name isEqualToString:@"media_sources"]) return [self mediaSourcesPage];
  if ([name isEqualToString:@"places"]) return [self placesPage];
  if ([name isEqualToString:@"devices"]) return [self devicesPage];
  if ([name isEqualToString:@"wording"]) return [self wordingPage];
  if ([name isEqualToString:@"theme"]) return [self themePage];
  if ([name isEqualToString:@"sounds"]) return [self soundsPage];
  if ([name isEqualToString:@"config_transfer"]) return [self configTransferPage];
  if ([name isEqualToString:@"admin_password"]) return [self adminPasswordPage];
  return nil;
}

#pragma mark - quick replies

- (DBEditPage *)quickRepliesPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *root = @"quick_replies";
  DBEditPage *page = [DBEditPage title:[self t:@"prefs.quick_replies"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *replies = DBDict([pages at:root]);
    NSArray *ids = [DBConfigUtil sortedByOrder:replies];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *reply in ids) {
      NSDictionary *entry = DBDict([replies objectForKey:reply]);
      BOOL speak = [DBConfigUtil boolVal:entry path:@"speak" def:YES];
      [fields addObject:[pages page:[pages label:entry fallback:reply]
                             detail:(speak ? [pages t:@"editor.speak_on"] : @"")
                              build:^DBEditPage *{ return [weakSelf quickReplyPage:reply]; }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.list_edit_hint"];
    section.onDelete = ^BOOL(NSInteger index) {
      NSArray *now = [DBConfigUtil sortedByOrder:DBDict([weakSelf at:root])];
      if (index >= (NSInteger)[now count]) return NO;
      return [weakSelf deleteKey:[NSString stringWithFormat:@"%@.%@", root,
                                                            [now objectAtIndex:(NSUInteger)index]]];
    };
    section.onMove = ^BOOL(NSInteger from, NSInteger to) {
      return [weakSelf moveIn:root from:from to:to];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"editor.new_reply"] value:@"" placeholder:nil
               keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
      DBSettingsPages *inner = weakSelf;
      NSString *label = DBTrim(text);
      if (!inner || [label length] == 0) return;
      NSString *reply = [inner newIdWithPrefix:@"qr_" in:root];
      NSDictionary *entry = @{ @"label" : @{ [inner lang] : label }, @"speak" : @YES,
                               @"order" : [NSNumber numberWithInteger:[inner nextOrderIn:root]] };
      if ([inner setKey:[NSString stringWithFormat:@"%@.%@", root, reply] value:entry]) {
        [editor reloadPage];
        [editor pushPage:[inner quickReplyPage:reply]];
      }
    }];
  };
  return page;
}

- (DBEditPage *)quickReplyPage:(NSString *)reply {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *base = [NSString stringWithFormat:@"quick_replies.%@", reply];
  return [DBEditPage title:[self label:[self at:base] fallback:reply] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditSection *labels = [DBEditSection title:[pages t:@"editor.label"]
                                          fields:[pages localizedFields:[base stringByAppendingString:@".label"]]];
    DBEditField *speak = [pages toggle:[pages t:@"editor.speak"]
                                   key:[base stringByAppendingString:@".speak"] def:YES];
    DBEditField *remove = [pages action:[pages t:@"editor.delete"] block:^{
      if ([weakSelf deleteKey:base]) [editor popPage];
    }];
    remove.destructive = YES;
    return @[ labels, [DBEditSection title:nil fields:@[ speak ]],
              [DBEditSection title:nil fields:@[ remove ]] ];
  }];
}

#pragma mark - visit purposes

- (DBEditPage *)purposesPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *root = @"visit_purposes";
  DBEditPage *page = [DBEditPage title:[self t:@"editor.purposes"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *purposes = DBDict([pages at:root]);
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *purpose in [DBConfigUtil sortedByOrder:purposes]) {
      NSDictionary *entry = DBDict([purposes objectForKey:purpose]);
      NSString *icon = [DBConfigUtil str:entry path:@"icon"] ?: @"";
      BOOL enabled = [DBConfigUtil boolVal:entry path:@"enabled" def:YES];
      [fields addObject:[pages page:[NSString stringWithFormat:@"%@  %@", icon,
                                        [pages label:entry fallback:purpose]]
                             detail:[pages t:(enabled ? @"purpose.enabled" : @"purpose.disabled")]
                              build:^DBEditPage *{ return [weakSelf purposePage:purpose]; }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.list_edit_hint"];
    section.onDelete = ^BOOL(NSInteger index) {
      NSArray *now = [DBConfigUtil sortedByOrder:DBDict([weakSelf at:root])];
      if (index >= (NSInteger)[now count]) return NO;
      return [weakSelf deleteKey:[NSString stringWithFormat:@"%@.%@", root,
                                                            [now objectAtIndex:(NSUInteger)index]]];
    };
    section.onMove = ^BOOL(NSInteger from, NSInteger to) {
      return [weakSelf moveIn:root from:from to:to];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"editor.new_purpose"] value:@"" placeholder:nil
               keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
      DBSettingsPages *inner = weakSelf;
      NSString *label = DBTrim(text);
      if (!inner || [label length] == 0) return;
      NSString *purpose = [inner newIdWithPrefix:@"p_" in:root];
      NSDictionary *entry = @{ @"label" : @{ [inner lang] : label }, @"icon" : @"🔔",
                               @"enabled" : @YES,
                               @"order" : [NSNumber numberWithInteger:[inner nextOrderIn:root]] };
      if ([inner setKey:[NSString stringWithFormat:@"%@.%@", root, purpose] value:entry]) {
        [editor reloadPage];
        [editor pushPage:[inner purposePage:purpose]];
      }
    }];
  };
  return page;
}

- (DBEditPage *)purposePage:(NSString *)purpose {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *base = [NSString stringWithFormat:@"visit_purposes.%@", purpose];
  return [DBEditPage title:[self label:[self at:base] fallback:purpose] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditSection *labels = [DBEditSection title:[pages t:@"editor.label"]
                                          fields:[pages localizedFields:[base stringByAppendingString:@".label"]]];
    DBEditField *icon = [pages text:[pages t:@"editor.icon"] key:[base stringByAppendingString:@".icon"]];
    icon.placeholder = @"📦";
    DBEditField *enabled = [pages toggle:[pages t:@"purpose.enabled"]
                                     key:[base stringByAppendingString:@".enabled"] def:YES];
    DBEditField *remove = [pages action:[pages t:@"editor.delete"] block:^{
      if ([weakSelf deleteKey:base]) [editor popPage];
    }];
    remove.destructive = YES;
    return @[ labels, [DBEditSection title:nil fields:@[ icon, enabled ]],
              [DBEditSection title:nil fields:@[ remove ]] ];
  }];
}

#pragma mark - announcement presets

- (DBEditPage *)noticePresetsPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *key = @"notice.presets";
  DBEditPage *page = [DBEditPage title:[self t:@"notice.presets"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSArray *presets = DBArray([pages at:key]);
    NSMutableArray *fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < [presets count]; i++) {
      NSDictionary *preset = DBDict([presets objectAtIndex:i]);
      NSString *text = [DBConfigUtil str:preset path:@"text"] ?: @"";
      DBEditField *field = [DBEditField kind:DBEditKindText title:text value:text];
      field.onChange = ^BOOL(id value) {
        NSString *next = DBTrim([value description]);
        NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
        if (i >= [list count] || [next length] == 0 || [next length] > 200) return NO;
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:
            DBDict([list objectAtIndex:i])];
        [entry setObject:next forKey:@"text"];
        [list replaceObjectAtIndex:i withObject:entry];
        return [weakSelf setKey:key value:list];
      };
      [fields addObject:field];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.presets_hint"];
    section.onDelete = ^BOOL(NSInteger index) {
      NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
      if (index >= (NSInteger)[list count]) return NO;
      [list removeObjectAtIndex:(NSUInteger)index];
      return [weakSelf setKey:key value:list];
    };
    section.onMove = ^BOOL(NSInteger from, NSInteger to) {
      NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
      if (from >= (NSInteger)[list count] || to >= (NSInteger)[list count]) return NO;
      id moved = [list objectAtIndex:(NSUInteger)from];
      [list removeObjectAtIndex:(NSUInteger)from];
      [list insertObject:moved atIndex:(NSUInteger)to];
      return [weakSelf setKey:key value:list];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    if ([DBArray([pages at:key]) count] >= 8) {
      [editor showMessage:@"≤ 8"];
      return;
    }
    [editor promptTitle:[pages t:@"notice.presets"] value:@"" placeholder:nil
               keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
      NSString *value = DBTrim(text);
      if ([value length] == 0 || [value length] > 200) return;
      NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
      [list addObject:@{ @"id" : [@"np_" stringByAppendingString:DBRandomHex(4) ?: @"x"],
                         @"text" : value }];
      if ([weakSelf setKey:key value:list]) [editor reloadPage];
    }];
  };
  return page;
}

#pragma mark - quiet hours and schedule windows

- (NSArray *)weekdayChoices {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *day in @[ @"mon", @"tue", @"wed", @"thu", @"fri", @"sat", @"sun" ])
    [choices addObject:@[ day, [self t:[@"editor.day_" stringByAppendingString:day]] ]];
  return choices;
}

- (NSArray *)actionTypeChoices {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *type in @[ @"chime", @"device_alert", @"sip_call", @"telegram", @"ha_event",
                            @"ha_command", @"auto_reply" ])
    [choices addObject:@[ type, [self t:[@"editor.action_" stringByAppendingString:type]] ]];
  return choices;
}

- (NSString *)windowSummary:(NSDictionary *)window {
  NSString *from = [DBConfigUtil str:window path:@"from"] ?: @"--:--";
  NSString *to = [DBConfigUtil str:window path:@"to"] ?: @"--:--";
  NSArray *days = DBArray([window objectForKey:@"days"]);
  NSMutableArray *labels = [NSMutableArray array];
  for (NSString *day in days)
    if ([day isKindOfClass:[NSString class]])
      [labels addObject:[self t:[@"editor.day_" stringByAppendingString:day]]];
  return [labels count] > 0 && [labels count] < 7
      ? [NSString stringWithFormat:@"%@–%@  %@", from, to, [labels componentsJoinedByString:@" "]]
      : [NSString stringWithFormat:@"%@–%@", from, to];
}

// Time windows stored as an array at key: [{from, to, days?}].
- (DBEditSection *)windowsSection:(NSString *)key title:(NSString *)title {
  __weak DBSettingsPages *weakSelf = self;
  NSArray *windows = DBArray([self at:key]);
  NSMutableArray *fields = [NSMutableArray array];
  for (NSUInteger i = 0; i < [windows count]; i++) {
    NSDictionary *window = DBDict([windows objectAtIndex:i]);
    [fields addObject:[self page:[self windowSummary:window] detail:@""
                           build:^DBEditPage *{ return [weakSelf windowPage:key index:i]; }]];
  }
  [fields addObject:[self action:[self t:@"editor.add_window"] block:^{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([pages at:key])];
    [list addObject:@{ @"from" : @"22:00", @"to" : @"07:00" }];
    if ([pages setKey:key value:list]) [pages->_editor reloadPage];
  }]];
  DBEditSection *section = [DBEditSection title:title fields:fields];
  section.onDelete = ^BOOL(NSInteger index) {
    NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
    if (index >= (NSInteger)[list count]) return NO;
    [list removeObjectAtIndex:(NSUInteger)index];
    return [weakSelf setKey:key value:list];
  };
  return section;
}

- (BOOL)updateWindow:(NSString *)key index:(NSUInteger)index field:(NSString *)name value:(id)value {
  NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([self at:key])];
  if (index >= [list count]) return NO;
  NSMutableDictionary *window = [NSMutableDictionary dictionaryWithDictionary:
      DBDict([list objectAtIndex:index])];
  if (value == nil || ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] == 0))
    [window removeObjectForKey:name];
  else
    [window setObject:value forKey:name];
  [list replaceObjectAtIndex:index withObject:window];
  return [self setKey:key value:list];
}

- (DBEditPage *)windowPage:(NSString *)key index:(NSUInteger)index {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"editor.window"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSArray *list = DBArray([pages at:key]);
    NSDictionary *window = index < [list count] ? DBDict([list objectAtIndex:index]) : @{};
    DBEditField *from = [DBEditField kind:DBEditKindTime title:[pages t:@"editor.from"]
                                    value:[DBConfigUtil str:window path:@"from"] ?: @"22:00"];
    from.onChange = ^BOOL(id value) {
      return [weakSelf updateWindow:key index:index field:@"from" value:value];
    };
    DBEditField *to = [DBEditField kind:DBEditKindTime title:[pages t:@"editor.to"]
                                  value:[DBConfigUtil str:window path:@"to"] ?: @"07:00"];
    to.onChange = ^BOOL(id value) {
      return [weakSelf updateWindow:key index:index field:@"to" value:value];
    };
    DBEditField *days = [DBEditField kind:DBEditKindMulti title:[pages t:@"editor.weekdays"]
                                    value:DBArray([window objectForKey:@"days"])];
    days.choices = [pages weekdayChoices];
    days.onChange = ^BOOL(id value) {
      return [weakSelf updateWindow:key index:index field:@"days" value:value];
    };
    DBEditSection *section = [DBEditSection title:nil fields:@[ from, to, days ]];
    section.footer = [pages t:@"editor.weekdays_hint"];
    return @[ section ];
  }];
}

- (DBEditPage *)quietHoursPage {
  __weak DBSettingsPages *weakSelf = self;
  NSString *base = @"quiet_hours.default";
  return [DBEditPage title:[self t:@"settings.quiet_hours"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditSection *windows = [pages windowsSection:[base stringByAppendingString:@".windows"]
                                             title:[pages t:@"editor.windows"]];
    windows.footer = [pages t:@"editor.quiet_hint"];
    DBEditField *suppress = [DBEditField kind:DBEditKindMulti title:[pages t:@"editor.suppress"]
        value:DBArray([pages at:[base stringByAppendingString:@".suppress"]])];
    suppress.choices = [pages actionTypeChoices];
    suppress.onChange = ^BOOL(id value) {
      return [weakSelf setKey:[base stringByAppendingString:@".suppress"] value:value];
    };
    DBEditField *never = [DBEditField kind:DBEditKindMulti title:[pages t:@"editor.never_suppress"]
        value:DBArray([pages at:[base stringByAppendingString:@".never_suppress"]])];
    never.choices = [pages actionTypeChoices];
    never.onChange = ^BOOL(id value) {
      return [weakSelf setKey:[base stringByAppendingString:@".never_suppress"] value:value];
    };
    return @[ windows, [DBEditSection title:nil fields:@[ suppress, never ]] ];
  }];
}

#pragma mark - trigger rules

- (NSString *)ruleName:(NSString *)ruleId rule:(NSDictionary *)rule {
  NSString *name = [DBConfigUtil str:rule path:@"name"];
  if ([name length] > 0) return name;
  NSString *key = [NSString stringWithFormat:@"prefs.rule_%@", ruleId];
  NSString *known = [self t:key];
  return [known isEqualToString:key] ? ruleId : known;
}

- (NSArray *)whenTypeChoices {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *type in @[ @"button", @"motion", @"call_missed", @"device_offline",
                            @"emergency_on", @"emergency_off" ])
    [choices addObject:@[ type, [self t:[@"editor.when_" stringByAppendingString:type]] ]];
  return choices;
}

- (DBEditPage *)rulesPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[self t:@"prefs.rule_edit"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *rules = DBDict([pages at:@"trigger_rules"]);
    NSArray *ids = [[rules allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *ruleId in ids) {
      NSDictionary *rule = DBDict([rules objectForKey:ruleId]);
      BOOL enabled = [DBConfigUtil boolVal:rule path:@"enabled" def:YES];
      NSString *when = [DBConfigUtil str:rule path:@"when.type"] ?: @"";
      NSString *detail = [NSString stringWithFormat:@"%@ · %@",
          [pages t:[@"editor.when_" stringByAppendingString:when]],
          [pages t:(enabled ? @"editor.on" : @"editor.off")]];
      [fields addObject:[pages page:[pages ruleName:ruleId rule:rule] detail:detail
                              build:^DBEditPage *{ return [weakSelf rulePage:ruleId]; }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.onDelete = ^BOOL(NSInteger index) {
      NSArray *now = [[DBDict([weakSelf at:@"trigger_rules"]) allKeys]
          sortedArrayUsingSelector:@selector(compare:)];
      if (index >= (NSInteger)[now count]) return NO;
      return [weakSelf deleteKey:[@"trigger_rules." stringByAppendingString:
                                     [now objectAtIndex:(NSUInteger)index]]];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"editor.new_rule"] value:@"" placeholder:nil
               keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
      DBSettingsPages *inner = weakSelf;
      NSString *name = DBTrim(text);
      if (!inner || [name length] == 0) return;
      NSString *ruleId = [inner newIdWithPrefix:@"r_" in:@"trigger_rules"];
      NSDictionary *rule = @{ @"enabled" : @YES, @"name" : name,
                              @"when" : @{ @"type" : @"button" },
                              @"schedule" : @{ @"always" : @YES },
                              @"actions" : @[ @{ @"type" : @"chime" } ] };
      if ([inner setKey:[@"trigger_rules." stringByAppendingString:ruleId] value:rule]) {
        [editor reloadPage];
        [editor pushPage:[inner rulePage:ruleId]];
      }
    }];
  };
  return page;
}

- (DBEditPage *)rulePage:(NSString *)ruleId {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *base = [@"trigger_rules." stringByAppendingString:ruleId];
  return [DBEditPage title:[self ruleName:ruleId rule:DBDict([self at:base])] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *rule = DBDict([pages at:base]);
    DBEditField *name = [pages text:[pages t:@"editor.name"] key:[base stringByAppendingString:@".name"]];
    DBEditField *enabled = [pages toggle:[pages t:@"editor.enabled"]
                                     key:[base stringByAppendingString:@".enabled"] def:YES];
    DBEditField *type = [pages choice:[pages t:@"editor.when"]
                                  key:[base stringByAppendingString:@".when.type"] def:@"button"
                              choices:[pages whenTypeChoices]];
    NSMutableArray *when = [NSMutableArray arrayWithObject:type];
    NSString *whenType = [DBConfigUtil str:rule path:@"when.type"] ?: @"button";
    if ([whenType isEqualToString:@"button"] || [whenType isEqualToString:@"motion"] ||
        [whenType isEqualToString:@"call_missed"]) {
      NSString *doorsKey = [base stringByAppendingString:@".when.doors"];
      DBEditField *doors = [DBEditField kind:DBEditKindMulti title:[pages t:@"editor.doors"]
                                       value:DBArray([pages at:doorsKey])];
      doors.choices = [pages doorChoices];
      doors.detail = [DBArray([pages at:doorsKey]) count] == 0 ? [pages t:@"editor.all"] : nil;
      doors.onChange = ^BOOL(id value) {
        return [(NSArray *)value count] == 0 ? [weakSelf deleteKey:doorsKey]
                                            : [weakSelf setKey:doorsKey value:value];
      };
      [when addObject:doors];
    }
    if ([whenType isEqualToString:@"button"]) {
      NSString *purposesKey = [base stringByAppendingString:@".when.purposes"];
      DBEditField *purposes = [DBEditField kind:DBEditKindMulti title:[pages t:@"editor.purposes"]
                                          value:DBArray([pages at:purposesKey])];
      purposes.choices = [pages purposeChoices];
      purposes.detail = [DBArray([pages at:purposesKey]) count] == 0 ? [pages t:@"editor.all"] : nil;
      purposes.onChange = ^BOOL(id value) {
        return [(NSArray *)value count] == 0 ? [weakSelf deleteKey:purposesKey]
                                            : [weakSelf setKey:purposesKey value:value];
      };
      [when addObject:purposes];
    }
    // Schedule: always, or the listed windows.
    NSString *alwaysKey = [base stringByAppendingString:@".schedule.always"];
    NSString *windowsKey = [base stringByAppendingString:@".schedule.windows"];
    BOOL always = [DBArray([pages at:windowsKey]) count] == 0 ||
        [DBConfigUtil boolVal:[pages cfg] path:alwaysKey def:NO];
    DBEditField *alwaysField = [DBEditField kind:DBEditKindBool title:[pages t:@"editor.always"]
                                           value:[NSNumber numberWithBool:always]];
    alwaysField.onChange = ^BOOL(id value) {
      DBSettingsPages *inner = weakSelf;
      if ([value boolValue])
        return [inner commit:@[ [inner set:[base stringByAppendingString:@".schedule"]
                                     value:@{ @"always" : @YES }] ]];
      return [inner commit:@[ [inner set:[base stringByAppendingString:@".schedule"]
          value:@{ @"windows" : @[ @{ @"days" : @[ @"mon", @"tue", @"wed", @"thu", @"fri",
                                                    @"sat", @"sun" ],
                                       @"from" : @"08:00", @"to" : @"20:00" } ] }] ]];
    };
    NSMutableArray *sections = [NSMutableArray arrayWithObjects:
        [DBEditSection title:nil fields:@[ name, enabled ]],
        [DBEditSection title:[pages t:@"editor.when"] fields:when],
        [DBEditSection title:[pages t:@"editor.schedule"] fields:@[ alwaysField ]], nil];
    if (!always) [sections addObject:[pages windowsSection:windowsKey title:nil]];
    [sections addObject:[pages actionsSection:[base stringByAppendingString:@".actions"]]];
    DBEditField *remove = [pages action:[pages t:@"editor.delete"] block:^{
      if ([weakSelf deleteKey:base]) [editor popPage];
    }];
    remove.destructive = YES;
    [sections addObject:[DBEditSection title:nil fields:@[ remove ]]];
    return sections;
  }];
}

- (NSString *)actionSummary:(NSDictionary *)action {
  NSString *type = [DBConfigUtil str:action path:@"type"] ?: @"";
  NSString *label = [self t:[@"editor.action_" stringByAppendingString:type]];
  NSString *extra = nil;
  if ([type isEqualToString:@"sip_call"]) extra = [DBConfigUtil str:action path:@"target_extension"];
  else if ([type isEqualToString:@"ha_command"]) extra = [DBConfigUtil str:action path:@"command"];
  else if ([type isEqualToString:@"auto_reply"]) extra = [DBConfigUtil str:action path:@"reply_id"];
  else if ([type isEqualToString:@"chime"]) extra = [DBConfigUtil str:action path:@"sound"];
  if ([DBConfigUtil boolVal:action path:@"never_suppress" def:NO])
    label = [label stringByAppendingFormat:@" · %@", [self t:@"editor.never_suppress_short"]];
  return [extra length] > 0 ? [NSString stringWithFormat:@"%@ (%@)", label, extra] : label;
}

- (DBEditSection *)actionsSection:(NSString *)key {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSArray *actions = DBArray([self at:key]);
  NSMutableArray *fields = [NSMutableArray array];
  for (NSUInteger i = 0; i < [actions count]; i++) {
    NSDictionary *action = DBDict([actions objectAtIndex:i]);
    [fields addObject:[self page:[self actionSummary:action] detail:@""
                           build:^DBEditPage *{ return [weakSelf actionPage:key index:i]; }]];
  }
  DBEditField *add = [DBEditField kind:DBEditKindChoice title:[self t:@"editor.add_action"]
                                 value:nil];
  add.detail = @"";
  add.choices = [self actionTypeChoices];
  add.onChange = ^BOOL(id value) {
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([pages at:key])];
    NSMutableDictionary *action = [NSMutableDictionary dictionaryWithObject:value forKey:@"type"];
    if ([value isEqualToString:@"device_alert"]) {
      [action setObject:@{ @"roles" : @"all" } forKey:@"targets"];
      [action setObject:@[ @"in_app" ] forKey:@"channels"];
      [action setObject:@{ @"visual" : @YES } forKey:@"presentation"];
    } else if ([value isEqualToString:@"telegram"]) {
      [action setObject:@"all" forKey:@"households"];
    } else if ([value isEqualToString:@"chime"]) {
      [action setObject:@"ding1" forKey:@"sound"];
    }
    [list addObject:action];
    BOOL ok = [pages setKey:key value:list];
    if (ok) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [editor pushPage:[weakSelf actionPage:key index:[list count] - 1]];
      });
    }
    return ok;
  };
  [fields addObject:add];
  DBEditSection *section = [DBEditSection title:[self t:@"editor.actions"] fields:fields];
  section.onDelete = ^BOOL(NSInteger index) {
    NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([weakSelf at:key])];
    if (index >= (NSInteger)[list count]) return NO;
    [list removeObjectAtIndex:(NSUInteger)index];
    return [weakSelf setKey:key value:list];
  };
  return section;
}

- (BOOL)updateAction:(NSString *)key index:(NSUInteger)index path:(NSString *)path value:(id)value {
  NSMutableArray *list = [NSMutableArray arrayWithArray:DBArray([self at:key])];
  if (index >= [list count]) return NO;
  NSMutableDictionary *action = [(NSDictionary *)DBDict([list objectAtIndex:index]) mutableCopy];
  NSArray *parts = [path componentsSeparatedByString:@"."];
  if ([parts count] == 2) {
    NSMutableDictionary *inner = [DBDict([action objectForKey:[parts objectAtIndex:0]]) mutableCopy];
    if (value) [inner setObject:value forKey:[parts objectAtIndex:1]];
    else [inner removeObjectForKey:[parts objectAtIndex:1]];
    [action setObject:inner forKey:[parts objectAtIndex:0]];
  } else if (value) {
    [action setObject:value forKey:path];
  } else {
    [action removeObjectForKey:path];
  }
  [list replaceObjectAtIndex:index withObject:action];
  return [self setKey:key value:list];
}

- (DBEditPage *)actionPage:(NSString *)key index:(NSUInteger)index {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"editor.action"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSArray *list = DBArray([pages at:key]);
    NSDictionary *action = index < [list count] ? DBDict([list objectAtIndex:index]) : @{};
    NSString *type = [DBConfigUtil str:action path:@"type"] ?: @"";
    NSMutableArray *fields = [NSMutableArray array];
    DBEditField *(^text)(NSString *, NSString *, UIKeyboardType) =
        ^DBEditField *(NSString *title, NSString *path, UIKeyboardType keyboard) {
      DBEditField *field = [DBEditField kind:DBEditKindText title:title
                                       value:[DBConfigUtil str:action path:path] ?: @""];
      field.keyboard = keyboard;
      field.onChange = ^BOOL(id value) {
        NSString *trimmed = DBTrim([value description]);
        return [weakSelf updateAction:key index:index path:path
                                value:([trimmed length] ? trimmed : nil)];
      };
      return field;
    };
    DBEditField *(^flag)(NSString *, NSString *, BOOL) =
        ^DBEditField *(NSString *title, NSString *path, BOOL def) {
      DBEditField *field = [DBEditField kind:DBEditKindBool title:title
          value:[NSNumber numberWithBool:[DBConfigUtil boolVal:action path:path def:def]]];
      field.onChange = ^BOOL(id value) {
        return [weakSelf updateAction:key index:index path:path value:value];
      };
      return field;
    };
    DBEditField *(^multi)(NSString *, NSString *, NSArray *, BOOL) =
        ^DBEditField *(NSString *title, NSString *path, NSArray *choices, BOOL allowAll) {
      id current = [DBConfigUtil dig:action path:path];
      BOOL all = [current isEqual:@"all"];
      NSMutableArray *options = [NSMutableArray array];
      if (allowAll) [options addObject:@[ @"all", [pages t:@"editor.all"] ]];
      [options addObjectsFromArray:choices];
      DBEditField *field = [DBEditField kind:DBEditKindMulti title:title
                                       value:(all ? @[ @"all" ] : DBArray(current))];
      field.choices = options;
      field.onChange = ^BOOL(id value) {
        NSArray *picked = value;
        // "all" is a value of its own, never mixed with a list.
        id stored = picked;
        if (allowAll && [picked containsObject:@"all"])
          stored = ([picked lastObject] && [[picked lastObject] isEqual:@"all"]) || [picked count] == 1
              ? @"all" : [picked filteredArrayUsingPredicate:
                             [NSPredicate predicateWithFormat:@"SELF != 'all'"]];
        return [weakSelf updateAction:key index:index path:path value:stored];
      };
      return field;
    };
    DBEditField *typeField = [DBEditField kind:DBEditKindChoice title:[pages t:@"editor.type"]
                                         value:type];
    typeField.choices = [pages actionTypeChoices];
    typeField.onChange = ^BOOL(id value) {
      DBSettingsPages *inner = weakSelf;
      NSMutableArray *next = [NSMutableArray arrayWithArray:DBArray([inner at:key])];
      if (index >= [next count]) return NO;
      [next replaceObjectAtIndex:index withObject:@{ @"type" : value }];
      return [inner setKey:key value:next];
    };
    [fields addObject:typeField];
    if ([type isEqualToString:@"sip_call"]) {
      [fields addObject:text([pages t:@"editor.extension"], @"target_extension",
                             UIKeyboardTypeNumbersAndPunctuation)];
    } else if ([type isEqualToString:@"telegram"]) {
      [fields addObject:multi([pages t:@"editor.households"], @"households",
                              [pages householdChoices], YES)];
      [fields addObject:flag([pages t:@"editor.with_snapshot"], @"with_snapshot", NO)];
    } else if ([type isEqualToString:@"ha_command"]) {
      [fields addObject:text([pages t:@"editor.command"], @"command", UIKeyboardTypeASCIICapable)];
      NSMutableArray *doors = [NSMutableArray arrayWithObject:@[ @"self", [pages t:@"editor.this_door"] ]];
      [doors addObjectsFromArray:[pages doorChoices]];
      DBEditField *door = [DBEditField kind:DBEditKindChoice title:[pages t:@"editor.door"]
                                      value:[DBConfigUtil str:action path:@"door"] ?: @"self"];
      door.choices = doors;
      door.onChange = ^BOOL(id value) {
        return [weakSelf updateAction:key index:index path:@"door" value:value];
      };
      [fields addObject:door];
    } else if ([type isEqualToString:@"chime"]) {
      DBEditField *sound = [DBEditField kind:DBEditKindChoice title:[pages t:@"prefs.ringtone"]
                                       value:[DBConfigUtil str:action path:@"sound"] ?: @"ding1"];
      sound.choices = [pages soundChoices];
      sound.onChange = ^BOOL(id value) {
        return [weakSelf updateAction:key index:index path:@"sound" value:value];
      };
      [fields addObject:sound];
    } else if ([type isEqualToString:@"auto_reply"]) {
      DBEditField *reply = [DBEditField kind:DBEditKindChoice title:[pages t:@"prefs.quick_replies"]
                                       value:[DBConfigUtil str:action path:@"reply_id"] ?: @""];
      reply.choices = [pages replyChoices];
      reply.onChange = ^BOOL(id value) {
        return [weakSelf updateAction:key index:index path:@"reply_id" value:value];
      };
      [fields addObject:reply];
    } else if ([type isEqualToString:@"device_alert"]) {
      [fields addObject:multi([pages t:@"editor.target_roles"], @"targets.roles",
                              @[ @[ @"indoor_panel", [pages t:@"admin.role_indoor"] ],
                                 @[ @"door_station", [pages t:@"admin.role_door"] ] ], YES)];
      NSMutableArray *channels = [NSMutableArray array];
      for (NSString *channel in @[ @"in_app", @"system_notification", @"web_push" ])
        [channels addObject:@[ channel, [pages t:[@"editor.channel_" stringByAppendingString:channel]] ]];
      [fields addObject:multi([pages t:@"editor.channels"], @"channels", channels, NO)];
      [fields addObject:flag([pages t:@"editor.visual"], @"presentation.visual", YES)];
      [fields addObject:flag([pages t:@"editor.sticky"], @"presentation.sticky", NO)];
      DBEditField *ttl = [DBEditField kind:DBEditKindNumber title:[pages t:@"editor.ttl"]
          value:[NSNumber numberWithInteger:[DBConfigUtil intVal:action path:@"presentation.ttl_s"
                                                             def:30]]];
      ttl.minimum = 0;
      ttl.maximum = 86400;
      ttl.onChange = ^BOOL(id value) {
        return [weakSelf updateAction:key index:index path:@"presentation.ttl_s" value:value];
      };
      [fields addObject:ttl];
      DBEditField *sound = [DBEditField kind:DBEditKindChoice title:[pages t:@"prefs.ringtone"]
          value:[DBConfigUtil str:action path:@"presentation.sound"] ?: @""];
      NSMutableArray *sounds = [NSMutableArray arrayWithObject:@[ @"", [pages t:@"prefs.sound_none"] ]];
      [sounds addObjectsFromArray:[pages soundChoices]];
      sound.choices = sounds;
      sound.onChange = ^BOOL(id value) {
        return [weakSelf updateAction:key index:index path:@"presentation.sound"
                                value:([value length] ? value : nil)];
      };
      [fields addObject:sound];
    }
    DBEditSection *settings = [DBEditSection title:nil fields:fields];
    DBEditField *never = flag([pages t:@"editor.never_suppress"], @"never_suppress", NO);
    DBEditSection *quiet = [DBEditSection title:nil fields:@[ never ]];
    quiet.footer = [pages t:@"editor.never_suppress_hint"];
    return @[ settings, quiet ];
  }];
}

#pragma mark - administrator HTTP session

// Panels, configuration import and the Telegram test need an administrator
// HTTP session on this node. The password is asked for once per editor visit
// and is not kept.
- (void)withSession:(void (^)(DBAdminHttpSession *session))then {
  if (_http) {
    then(_http);
    return;
  }
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  [_editor promptTitle:[self t:@"editor.password_for_session"] value:@"" placeholder:nil
              keyboard:UIKeyboardTypeASCIICapable secure:YES then:^(NSString *text) {
    DBSettingsPages *pages = weakSelf;
    if (!pages || [text length] == 0) return;
    NSInteger port = pages->_boot.httpPort > 0 ? pages->_boot.httpPort : 47180;
    [DBAdminHttpSession openWithPassword:text port:port
                              completion:^(DBAdminHttpSession *session, NSString *error) {
      DBSettingsPages *inner = weakSelf;
      if (!inner) return;
      if (session == nil) {
        [editor showMessage:[inner t:([error isEqualToString:@"password"]
                                          ? @"editor.password_wrong" : @"editor.unreachable")]];
        return;
      }
      inner->_http = session;
      then(session);
    }];
  }];
}

#pragma mark - Telegram, households and secrets

- (DBEditPage *)telegramPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *tokenKey = @"integrations.telegram.bot_token_ref";
  return [DBEditPage title:@"Telegram" build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    BOOL configured = [pages hasSecretAt:tokenKey];
    DBEditField *token = [pages secret:[pages t:@"editor.bot_token"] key:tokenKey base:@"tg_bot"];
    DBEditField *poll = [pages toggle:[pages t:@"editor.poll_updates"]
                                  key:@"integrations.telegram.poll_updates" def:YES];
    DBEditSection *main = [DBEditSection title:nil fields:@[ token, poll ]];
    main.footer = [pages t:@"editor.secret_hint"];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:main];
    [sections addObject:[DBEditSection title:nil fields:@[
        [pages page:[pages t:@"editor.households"] detail:nil
              build:^DBEditPage *{ return [weakSelf householdsPage]; }] ]]];
    if (configured) {
      DBEditField *test = [pages action:[pages t:@"editor.test_message"] block:^{
        [weakSelf sendTelegramTest];
      }];
      DBEditField *disable = [pages action:[pages t:@"editor.disable"] block:^{
        if ([weakSelf deleteKey:tokenKey]) [editor reloadPage];
      }];
      disable.destructive = YES;
      [sections addObject:[DBEditSection title:nil fields:@[ test, disable ]]];
    }
    return sections;
  }];
}

- (void)sendTelegramTest {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *chat = @"";
  NSDictionary *households = DBDict([self at:@"households"]);
  for (NSString *household in [DBConfigUtil sortedByOrder:households]) {
    NSArray *ids = DBArray([DBDict([households objectForKey:household])
        objectForKey:@"telegram_chat_ids"]);
    if ([ids count] > 0) {
      chat = [[ids objectAtIndex:0] description];
      break;
    }
  }
  [_editor promptTitle:[self t:@"editor.chat_id"] value:chat placeholder:@"123456789"
              keyboard:UIKeyboardTypeNumbersAndPunctuation secure:NO then:^(NSString *text) {
    NSString *target = DBTrim(text);
    if ([target length] == 0) return;
    [weakSelf withSession:^(DBAdminHttpSession *session) {
      [session request:@"POST" path:@"/api/test/telegram" body:@{ @"chat_id" : target }
            completion:^(NSInteger status, NSDictionary *json) {
        DBSettingsPages *pages = weakSelf;
        BOOL ok = status == 200 && [[json objectForKey:@"ok"] boolValue];
        [editor showMessage:ok ? [pages t:@"admin.test_sent"]
            : [NSString stringWithFormat:@"%@ %@", [pages t:@"settings.save_failed"],
                  [DBConfigUtil evStr:json key:@"err"] ?: @""]];
      }];
    }];
  }];
}

- (DBEditPage *)householdsPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[self t:@"editor.households"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *households = DBDict([pages at:@"households"]);
    NSArray *ids = [DBConfigUtil sortedByOrder:households];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *household in ids) {
      NSDictionary *entry = DBDict([households objectForKey:household]);
      NSString *chats = [DBArray([entry objectForKey:@"telegram_chat_ids"])
          componentsJoinedByString:@", "];
      [fields addObject:[pages page:[pages label:entry fallback:household] detail:chats
                              build:^DBEditPage *{ return [weakSelf householdPage:household]; }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.onDelete = ^BOOL(NSInteger index) {
      NSArray *now = [DBConfigUtil sortedByOrder:DBDict([weakSelf at:@"households"])];
      if (index >= (NSInteger)[now count]) return NO;
      return [weakSelf deleteKey:[@"households." stringByAppendingString:
                                     [now objectAtIndex:(NSUInteger)index]]];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"editor.new_household"] value:@"" placeholder:nil
               keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
      DBSettingsPages *inner = weakSelf;
      NSString *label = DBTrim(text);
      if (!inner || [label length] == 0) return;
      NSString *household = [inner newIdWithPrefix:@"h_" in:@"households"];
      if ([inner setKey:[@"households." stringByAppendingString:household]
                  value:@{ @"label" : @{ [inner lang] : label } }])
        [editor reloadPage];
    }];
  };
  return page;
}

- (DBEditPage *)householdPage:(NSString *)household {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *base = [@"households." stringByAppendingString:household];
  return [DBEditPage title:[self label:[self at:base] fallback:household] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditSection *labels = [DBEditSection title:[pages t:@"editor.label"]
        fields:[pages localizedFields:[base stringByAppendingString:@".label"]]];
    NSString *chatsKey = [base stringByAppendingString:@".telegram_chat_ids"];
    DBEditField *chats = [DBEditField kind:DBEditKindText title:[pages t:@"editor.chat_ids"]
        value:[DBArray([pages at:chatsKey]) componentsJoinedByString:@", "]];
    chats.keyboard = UIKeyboardTypeNumbersAndPunctuation;
    chats.placeholder = @"123456789, -100123";
    chats.onChange = ^BOOL(id value) {
      NSMutableArray *ids = [NSMutableArray array];
      for (NSString *part in [[value description] componentsSeparatedByString:@","]) {
        NSString *trimmed = DBTrim(part);
        if ([trimmed length] == 0) continue;
        long long number = [trimmed longLongValue];
        if (number == 0) {
          [editor showMessage:trimmed];
          return NO;
        }
        [ids addObject:[NSNumber numberWithLongLong:number]];
      }
      return [ids count] == 0 ? [weakSelf deleteKey:chatsKey] : [weakSelf setKey:chatsKey value:ids];
    };
    NSString *extKey = [base stringByAppendingString:@".sip_extensions"];
    DBEditField *extensions = [DBEditField kind:DBEditKindText title:[pages t:@"editor.sip_extensions"]
        value:[DBArray([pages at:extKey]) componentsJoinedByString:@", "]];
    extensions.keyboard = UIKeyboardTypeNumbersAndPunctuation;
    extensions.onChange = ^BOOL(id value) {
      NSMutableArray *list = [NSMutableArray array];
      for (NSString *part in [[value description] componentsSeparatedByString:@","])
        if ([DBTrim(part) length] > 0) [list addObject:DBTrim(part)];
      return [list count] == 0 ? [weakSelf deleteKey:extKey] : [weakSelf setKey:extKey value:list];
    };
    DBEditField *remove = [pages action:[pages t:@"editor.delete"] block:^{
      if ([weakSelf deleteKey:base]) [editor popPage];
    }];
    remove.destructive = YES;
    return @[ labels, [DBEditSection title:nil fields:@[ chats, extensions ]],
              [DBEditSection title:nil fields:@[ remove ]] ];
  }];
}

- (DBEditPage *)secretsPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"editor.secrets"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    if ([pages.nodeId length] > 0)
      [fields addObject:[pages secret:[pages t:@"editor.sip_password"]
          key:[NSString stringWithFormat:@"sip.accounts.%@.pass_ref", pages.nodeId]
         base:[@"sip." stringByAppendingString:pages.nodeId]]];
    [fields addObject:[pages secret:[pages t:@"editor.mqtt_password"]
                                key:@"integrations.mqtt.pass_ref" base:@"mqtt"]];
    [fields addObject:[pages secret:[pages t:@"editor.bot_token"]
                                key:@"integrations.telegram.bot_token_ref" base:@"tg_bot"]];
    NSDictionary *sources = DBDict([pages at:@"media_sources"]);
    for (NSString *source in [[sources allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      if (!DBSafeId(source)) continue;
      [fields addObject:[pages secret:[NSString stringWithFormat:@"%@ · %@",
                                          [pages t:@"editor.camera_credential"], source]
                                  key:[NSString stringWithFormat:@"media_sources.%@.secret_ref", source]
                                 base:[@"media." stringByAppendingString:source]]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.secret_hint"];
    return @[ section ];
  }];
}

#pragma mark - SIP

- (DBEditPage *)sipPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:@"SIP" build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *server = [pages text:[pages t:@"editor.server"] key:@"sip.server"];
    server.keyboard = UIKeyboardTypeURL;
    server.placeholder = @"10.0.1.5";
    DBEditField *port = [pages number:[pages t:@"editor.port"] key:@"sip.port" def:5060 min:1
                                  max:65535];
    DBEditField *transport = [pages choice:[pages t:@"editor.transport"] key:@"sip.transport"
                                       def:@"udp"
                                   choices:@[ @[ @"udp", @"UDP" ], @[ @"tcp", @"TCP" ],
                                              @[ @"tls", @"TLS" ] ]];
    DBEditField *direct = [pages number:[pages t:@"editor.direct_port"] key:@"sip.direct_port"
                                    def:47190 min:1024 max:65535];
    DBEditField *srtp = [pages choice:@"SRTP" key:@"sip.srtp" def:@"optional"
                              choices:@[ @[ @"optional", [pages t:@"editor.srtp_optional"] ],
                                         @[ @"mandatory", [pages t:@"editor.srtp_mandatory"] ] ]];
    DBEditSection *server_section = [DBEditSection title:nil
        fields:@[ server, port, transport, direct, srtp ]];
    server_section.footer = [pages t:@"editor.srtp_hint"];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:server_section];
    if ([pages.nodeId length] > 0) {
      NSString *account = [@"sip.accounts." stringByAppendingString:pages.nodeId];
      DBEditField *user = [pages text:[pages t:@"editor.sip_user"]
                                  key:[account stringByAppendingString:@".user"]];
      user.keyboard = UIKeyboardTypeASCIICapable;
      DBEditField *pass = [pages secret:[pages t:@"editor.sip_password"]
                                    key:[account stringByAppendingString:@".pass_ref"]
                                   base:[@"sip." stringByAppendingString:pages.nodeId]];
      DBEditField *answer = [pages choice:[pages t:@"editor.answer_mode"]
                                      key:[account stringByAppendingString:@".answer_mode"]
                                      def:([pages->_boot.role isEqualToString:@"door_station"]
                                               ? @"auto" : @"ring")
                                  choices:@[ @[ @"auto", [pages t:@"editor.answer_auto"] ],
                                             @[ @"ring", [pages t:@"editor.answer_ring"] ] ]];
      [sections addObject:[DBEditSection title:[pages t:@"editor.this_device"]
                                        fields:@[ user, pass, answer ]]];
    }
    [sections addObject:[pages dtmfSection]];
    return sections;
  }];
}

- (NSString *)dtmfSummary:(NSDictionary *)action {
  NSString *type = [DBConfigUtil str:action path:@"type"] ?: @"";
  NSString *label = [self t:[@"editor.dtmf_" stringByAppendingString:type]];
  NSString *extra = [type isEqualToString:@"ha_command"] ? [DBConfigUtil str:action path:@"command"]
      : ([type isEqualToString:@"quick_reply"] ? [DBConfigUtil str:action path:@"reply_id"] : nil);
  return [extra length] ? [NSString stringWithFormat:@"%@ (%@)", label, extra] : label;
}

- (NSArray *)dtmfTypeChoices {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *type in @[ @"hangup", @"ha_command", @"quick_reply", @"decline" ])
    [choices addObject:@[ type, [self t:[@"editor.dtmf_" stringByAppendingString:type]] ]];
  return choices;
}

- (DBEditSection *)dtmfSection {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSDictionary *map = DBDict([self at:@"sip.dtmf_actions"]);
  NSArray *codes = [[map allKeys] sortedArrayUsingSelector:@selector(compare:)];
  NSMutableArray *fields = [NSMutableArray array];
  for (NSString *code in codes) {
    [fields addObject:[self page:code detail:[self dtmfSummary:DBDict([map objectForKey:code])]
                           build:^DBEditPage *{ return [weakSelf dtmfPage:code]; }]];
  }
  [fields addObject:[self action:[self t:@"editor.add_dtmf"] block:^{
    DBSettingsPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"editor.dtmf_code"] value:@"*" placeholder:@"*1"
               keyboard:UIKeyboardTypeNumbersAndPunctuation secure:NO then:^(NSString *text) {
      DBSettingsPages *inner = weakSelf;
      NSString *code = [DBTrim(text) uppercaseString];
      NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
          @"0123456789*#ABCD"] invertedSet];
      if ([code length] < 1 || [code length] > 8 ||
          [code rangeOfCharacterFromSet:bad].location != NSNotFound) {
        [editor showMessage:[inner t:@"editor.dtmf_code_hint"]];
        return;
      }
      // The code is a map key; the whole map is written so '*' and '#' never
      // have to survive a dotted key path.
      NSMutableDictionary *next = [DBDict([inner at:@"sip.dtmf_actions"]) mutableCopy];
      [next setObject:@{ @"type" : @"hangup" } forKey:code];
      if ([inner setKey:@"sip.dtmf_actions" value:next]) {
        [editor reloadPage];
        [editor pushPage:[inner dtmfPage:code]];
      }
    }];
  }]];
  DBEditSection *section = [DBEditSection title:[self t:@"editor.dtmf_actions"] fields:fields];
  section.footer = [self t:@"editor.dtmf_hint"];
  section.onDelete = ^BOOL(NSInteger index) {
    DBSettingsPages *pages = weakSelf;
    NSMutableDictionary *next = [DBDict([pages at:@"sip.dtmf_actions"]) mutableCopy];
    NSArray *now = [[next allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if (index >= (NSInteger)[now count]) return NO;
    [next removeObjectForKey:[now objectAtIndex:(NSUInteger)index]];
    return [pages setKey:@"sip.dtmf_actions" value:next];
  };
  return section;
}

- (BOOL)setDtmf:(NSString *)code action:(NSDictionary *)action {
  NSMutableDictionary *next = [DBDict([self at:@"sip.dtmf_actions"]) mutableCopy];
  [next setObject:action forKey:code];
  return [self setKey:@"sip.dtmf_actions" value:next];
}

- (DBEditPage *)dtmfPage:(NSString *)code {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:code build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *action = DBDict([DBDict([pages at:@"sip.dtmf_actions"]) objectForKey:code]);
    NSString *type = [DBConfigUtil str:action path:@"type"] ?: @"hangup";
    DBEditField *typeField = [DBEditField kind:DBEditKindChoice title:[pages t:@"editor.type"]
                                         value:type];
    typeField.choices = [pages dtmfTypeChoices];
    typeField.onChange = ^BOOL(id value) {
      NSMutableDictionary *next = [NSMutableDictionary dictionaryWithObject:value forKey:@"type"];
      if ([value isEqualToString:@"ha_command"]) {
        [next setObject:@"unlock" forKey:@"command"];
        [next setObject:@"self" forKey:@"door"];
      } else if ([value isEqualToString:@"quick_reply"]) {
        NSArray *replies = [weakSelf replyChoices];
        if ([replies count] == 0) return NO;
        [next setObject:[[replies objectAtIndex:0] objectAtIndex:0] forKey:@"reply_id"];
      }
      return [weakSelf setDtmf:code action:next];
    };
    NSMutableArray *fields = [NSMutableArray arrayWithObject:typeField];
    if ([type isEqualToString:@"ha_command"]) {
      DBEditField *command = [DBEditField kind:DBEditKindText title:[pages t:@"editor.command"]
                                         value:[DBConfigUtil str:action path:@"command"] ?: @""];
      command.keyboard = UIKeyboardTypeASCIICapable;
      command.onChange = ^BOOL(id value) {
        NSMutableDictionary *next = [action mutableCopy];
        [next setObject:DBTrim([value description]) forKey:@"command"];
        return [weakSelf setDtmf:code action:next];
      };
      NSMutableArray *doors = [NSMutableArray arrayWithObject:@[ @"self", [pages t:@"editor.this_door"] ]];
      [doors addObjectsFromArray:[pages doorChoices]];
      DBEditField *door = [DBEditField kind:DBEditKindChoice title:[pages t:@"editor.door"]
                                      value:[DBConfigUtil str:action path:@"door"] ?: @"self"];
      door.choices = doors;
      door.onChange = ^BOOL(id value) {
        NSMutableDictionary *next = [action mutableCopy];
        [next setObject:value forKey:@"door"];
        return [weakSelf setDtmf:code action:next];
      };
      [fields addObject:command];
      [fields addObject:door];
    } else if ([type isEqualToString:@"quick_reply"]) {
      DBEditField *reply = [DBEditField kind:DBEditKindChoice title:[pages t:@"prefs.quick_replies"]
                                       value:[DBConfigUtil str:action path:@"reply_id"] ?: @""];
      reply.choices = [pages replyChoices];
      reply.onChange = ^BOOL(id value) {
        return [weakSelf setDtmf:code action:@{ @"type" : @"quick_reply", @"reply_id" : value }];
      };
      [fields addObject:reply];
    }
    return @[ [DBEditSection title:nil fields:fields] ];
  }];
}

#pragma mark - MQTT and Home Assistant

- (DBEditPage *)mqttPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"editor.mqtt"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSString *m = @"integrations.mqtt.";
    DBEditField *host = [pages text:[pages t:@"editor.server"] key:[m stringByAppendingString:@"host"]];
    host.keyboard = UIKeyboardTypeURL;
    DBEditField *port = [pages number:[pages t:@"editor.port"] key:[m stringByAppendingString:@"port"]
                                  def:1883 min:1 max:65535];
    DBEditField *tls = [pages toggle:@"TLS" key:[m stringByAppendingString:@"tls"] def:NO];
    DBEditField *pin = [pages text:[pages t:@"editor.tls_pin"]
                               key:[m stringByAppendingString:@"tls_sha256"]];
    pin.keyboard = UIKeyboardTypeASCIICapable;
    pin.placeholder = @"sha256 (64 hex)";
    DBEditField *user = [pages text:[pages t:@"editor.user"] key:[m stringByAppendingString:@"user"]];
    user.keyboard = UIKeyboardTypeASCIICapable;
    DBEditField *pass = [pages secret:[pages t:@"editor.mqtt_password"]
                                  key:[m stringByAppendingString:@"pass_ref"] base:@"mqtt"];
    DBEditField *topic = [pages text:[pages t:@"editor.base_topic"]
                                 key:[m stringByAppendingString:@"base_topic"]];
    topic.keyboard = UIKeyboardTypeASCIICapable;
    topic.placeholder = @"doorbell";
    DBEditField *discovery = [pages text:[pages t:@"editor.discovery_prefix"]
                                     key:[m stringByAppendingString:@"discovery_prefix"]];
    discovery.keyboard = UIKeyboardTypeASCIICapable;
    discovery.placeholder = @"homeassistant";
    DBEditSection *broker = [DBEditSection title:[pages t:@"editor.broker"]
        fields:@[ host, port, tls, pin, user, pass, topic, discovery ]];
    broker.footer = [pages t:@"editor.tls_hint"];
    NSString *h = @"integrations.ha.";
    DBEditField *language = [pages choice:[pages t:@"editor.entity_language"]
                                      key:[h stringByAppendingString:@"language"] def:@"ja"
                                  choices:[pages langChoices]];
    DBEditField *sos = [pages toggle:[pages t:@"editor.allow_sos_control"]
                                 key:[h stringByAppendingString:@"allow_sos_control"] def:NO];
    DBEditField *notice = [pages toggle:[pages t:@"editor.allow_notice_control"]
                                    key:[h stringByAppendingString:@"allow_notice_control"] def:NO];
    DBEditSection *ha = [DBEditSection title:@"Home Assistant" fields:@[ language, sos, notice ]];
    ha.footer = [pages t:@"editor.ha_control_hint"];
    return @[ broker, ha ];
  }];
}

#pragma mark - Web panels

static NSArray *DBPanelGrants(void) {
  return @[ @"view", @"call.monitor", @"call.answer", @"call.initiate", @"sos.trigger",
            @"door.open", @"media.publish", @"notice.write" ];
}

- (NSArray *)grantChoices {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *grant in DBPanelGrants()) {
    NSString *key = [@"panels.grant_" stringByAppendingString:
        [grant stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
    [choices addObject:@[ grant, [self t:key] ]];
  }
  return choices;
}

- (NSString *)adminHost {
  NSDictionary *status = [_core status];
  for (id address in DBArray([DBConfigUtil dig:status path:@"node.local_addrs"])) {
    if ([address isKindOfClass:[NSString class]] && [address rangeOfString:@":"].location == NSNotFound)
      return address;
  }
  return @"127.0.0.1";
}

// Panel identities live in Core behind the administrator session; the list is
// cached for the synchronous page builder and refreshed on every visit.
- (void)panelCall:(NSString *)action body:(NSDictionary *)body
             then:(void (^)(NSDictionary *result))then {
  __weak DBSettingsPages *weakSelf = self;
  [self withSession:^(DBAdminHttpSession *session) {
    DBSettingsPages *pages = weakSelf;
    if (!pages) return;
    NSMutableDictionary *request = [NSMutableDictionary dictionaryWithDictionary:body ?: @{}];
    if (![action isEqualToString:@"list"]) {
      // Each mutation names the configuration revision it was decided against.
      NSDictionary *list = [pages->_core panelIdentity:@"list" request:@{}
                                               session:session.session csrf:session.csrf];
      NSString *revision = [DBConfigUtil evStr:list key:@"revision"];
      if ([revision length] == 0) {
        [pages->_editor showMessage:[pages t:@"editor.unreachable"]];
        return;
      }
      [request setObject:revision forKey:@"expected_revision"];
    }
    NSDictionary *result = [pages->_core panelIdentity:action request:request
                                              session:session.session csrf:session.csrf];
    if (result == nil) {
      [pages->_editor showMessage:[pages t:@"editor.core_too_old"]];
      return;
    }
    if (![[result objectForKey:@"ok"] boolValue]) {
      NSString *code = [DBConfigUtil evStr:result key:@"error_code"] ?: @"";
      if ([code isEqualToString:@"permission_denied"]) pages->_http = nil;
      [pages->_editor showMessage:[NSString stringWithFormat:@"%@\n%@",
                                      [pages t:@"settings.save_failed"], code]];
      return;
    }
    then(result);
  }];
}

- (DBEditPage *)panelsPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  __block NSArray *panels = nil;
  DBEditPage *page = [DBEditPage title:[self t:@"prefs.panels"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    if (panels == nil) {
      [fields addObject:[DBEditField kind:DBEditKindInfo title:[pages t:@"editor.loading"] value:nil]];
    }
    NSDictionary *doors = DBDict([pages at:@"doors"]);
    for (NSDictionary *panel in panels) {
      NSString *panelId = [DBConfigUtil evStr:panel key:@"panel_id"];
      if ([panelId length] < 8) continue;
      NSMutableArray *scope = [NSMutableArray array];
      for (NSString *door in DBArray([panel objectForKey:@"door_scope"]))
        [scope addObject:[pages label:[doors objectForKey:door] fallback:door]];
      BOOL revoked = [[panel objectForKey:@"revoked"] boolValue];
      long long last = [[panel objectForKey:@"last_activity_ms"] longLongValue];
      NSString *activity = last > 0
          ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:last / 1000.0]
                                           dateStyle:NSDateFormatterShortStyle
                                           timeStyle:NSDateFormatterShortStyle]
          : @"—";
      NSString *detail = revoked ? [pages t:@"panels.revoked"]
          : [NSString stringWithFormat:@"%@ · %@ %@", [scope componentsJoinedByString:@", "],
                [pages t:@"panels.last_activity"], activity];
      NSDictionary *record = panel;
      [fields addObject:[pages page:[panelId substringToIndex:8] detail:detail
          build:^DBEditPage *{ return [weakSelf panelPage:record]; }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.panels_hint"];
    return @[ section ];
  }];
  page.onAppear = ^{
    [weakSelf panelCall:@"list" body:@{} then:^(NSDictionary *result) {
      panels = DBArray([result objectForKey:@"panels"]);
      [editor reloadPage];
    }];
  };
  page.onAdd = ^{
    [editor pushPage:[weakSelf newPanelPage:^{
      DBSettingsPages *pages = weakSelf;
      [pages panelCall:@"list" body:@{} then:^(NSDictionary *result) {
        panels = DBArray([result objectForKey:@"panels"]);
        [editor reloadPage];
      }];
    }]];
  };
  return page;
}

// Generates a credential, stores it in this device's Keychain and returns its
// reference; the bearer value itself only appears in the one-time link.
- (NSString *)provisionPanelCredential:(NSString **)credentialOut {
  NSString *credential = DBRandomHex(32);
  NSString *suffix = DBRandomHex(8);
  if ([credential length] == 0 || [suffix length] == 0) return nil;
  NSString *name = [@"panel." stringByAppendingString:suffix];
  if (![_core storeSecret:name value:credential]) return nil;
  if (credentialOut) *credentialOut = credential;
  return [@"secret:" stringByAppendingString:name];
}

- (DBEditPage *)newPanelPage:(void (^)(void))done {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSMutableDictionary *draft = [NSMutableDictionary dictionaryWithDictionary:@{
    @"door_scope" : @[], @"grants" : @[ @"view", @"call.monitor", @"call.answer" ] }];
  return [DBEditPage title:[self t:@"panels.create"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *doors = [DBEditField kind:DBEditKindMulti title:[pages t:@"panels.door_scope"]
                                     value:[draft objectForKey:@"door_scope"]];
    doors.choices = [pages doorChoices];
    doors.onChange = ^BOOL(id value) {
      [draft setObject:value forKey:@"door_scope"];
      return YES;
    };
    DBEditField *grants = [DBEditField kind:DBEditKindMulti title:[pages t:@"panels.grants"]
                                      value:[draft objectForKey:@"grants"]];
    grants.choices = [pages grantChoices];
    grants.onChange = ^BOOL(id value) {
      [draft setObject:value forKey:@"grants"];
      return YES;
    };
    DBEditField *create = [pages action:[pages t:@"panels.create"] block:^{
      DBSettingsPages *inner = weakSelf;
      if ([[draft objectForKey:@"door_scope"] count] == 0 ||
          [[draft objectForKey:@"grants"] count] == 0) {
        [editor showMessage:[inner t:@"panels.scope_required"]];
        return;
      }
      NSString *credential = nil;
      NSString *ref = [inner provisionPanelCredential:&credential];
      if (ref == nil) {
        [inner toast:@"editor.secret_store_failed"];
        return;
      }
      [inner panelCall:@"create"
                  body:@{ @"credential_ref" : ref, @"door_scope" : [draft objectForKey:@"door_scope"],
                          @"grants" : [draft objectForKey:@"grants"] }
                  then:^(NSDictionary *result) {
        (void)result;
        [editor popPage];
        if (done) done();
        [editor pushPage:[weakSelf panelLinkPage:credential]];
      }];
    }];
    return @[ [DBEditSection title:nil fields:@[ doors, grants ]],
              [DBEditSection title:nil fields:@[ create ]] ];
  }];
}

- (DBEditPage *)panelPage:(NSDictionary *)panel {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *panelId = [DBConfigUtil evStr:panel key:@"panel_id"];
  NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary:panel];
  return [DBEditPage title:[panelId substringToIndex:MIN((NSUInteger)8, [panelId length])]
                     build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    BOOL revoked = [[state objectForKey:@"revoked"] boolValue];
    if (revoked)
      return @[ [DBEditSection title:nil fields:@[
          [DBEditField kind:DBEditKindInfo title:[pages t:@"panels.revoked"] value:nil] ]] ];
    DBEditField *doors = [DBEditField kind:DBEditKindMulti title:[pages t:@"panels.door_scope"]
                                     value:DBArray([state objectForKey:@"door_scope"])];
    doors.choices = [pages doorChoices];
    doors.onChange = ^BOOL(id value) {
      if ([(NSArray *)value count] == 0) return NO;
      [weakSelf panelCall:@"update" body:@{ @"panel_id" : panelId, @"door_scope" : value }
                     then:^(NSDictionary *result) {
        (void)result;
        [state setObject:value forKey:@"door_scope"];
        [editor reloadPage];
      }];
      return NO;
    };
    DBEditField *grants = [DBEditField kind:DBEditKindMulti title:[pages t:@"panels.grants"]
                                      value:DBArray([state objectForKey:@"grants"])];
    grants.choices = [pages grantChoices];
    grants.onChange = ^BOOL(id value) {
      if ([(NSArray *)value count] == 0) return NO;
      [weakSelf panelCall:@"update" body:@{ @"panel_id" : panelId, @"grants" : value }
                     then:^(NSDictionary *result) {
        (void)result;
        [state setObject:value forKey:@"grants"];
        [editor reloadPage];
      }];
      return NO;
    };
    DBEditField *rotate = [pages action:[pages t:@"prefs.rotate_key"] block:^{
      DBSettingsPages *inner = weakSelf;
      NSString *credential = nil;
      NSString *ref = [inner provisionPanelCredential:&credential];
      if (ref == nil) {
        [inner toast:@"editor.secret_store_failed"];
        return;
      }
      [inner panelCall:@"rotate" body:@{ @"panel_id" : panelId, @"credential_ref" : ref }
                  then:^(NSDictionary *result) {
        (void)result;
        [editor pushPage:[weakSelf panelLinkPage:credential]];
      }];
    }];
    rotate.confirm = YES;
    DBEditField *revoke = [pages action:[pages t:@"panels.revoke"] block:^{
      [weakSelf panelCall:@"revoke" body:@{ @"panel_id" : panelId } then:^(NSDictionary *result) {
        (void)result;
        [state setObject:@YES forKey:@"revoked"];
        [editor showMessage:[weakSelf t:@"panels.revoked_done"]];
        [editor reloadPage];
      }];
    }];
    revoke.destructive = YES;
    return @[ [DBEditSection title:nil fields:@[ doors, grants ]],
              [DBEditSection title:nil fields:@[ rotate, revoke ]] ];
  }];
}

// The one-time links carry the credential in the URL fragment, which a browser
// never sends to a server. Shown once, as QR codes and text.
- (DBEditPage *)panelLinkPage:(NSString *)credential {
  __weak DBSettingsPages *weakSelf = self;
  NSString *host = [DBConfigUtil urlHost:[self adminHost]];
  return [DBEditPage title:[self t:@"panels.created"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *screen in @[ @"door", @"monitor", @"call" ]) {
      NSString *link = [NSString stringWithFormat:@"https://%@:47443/panel/%@#k=%@", host, screen,
                                                  credential];
      DBEditField *field = [DBEditField kind:DBEditKindInfo
                                       title:[pages t:[@"panels.link_" stringByAppendingString:screen]]
                                       value:link];
      field.image = [DBQrCode imageForString:link targetPx:240];
      [fields addObject:field];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.panel_link_once"];
    return @[ section ];
  }];
}

#pragma mark - external cameras

- (DBEditPage *)mediaSourcesPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[self t:@"prefs.media_sources"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *sources = DBDict([pages at:@"media_sources"]);
    NSArray *ids = [[sources allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *source in ids) {
      NSDictionary *entry = DBDict([sources objectForKey:source]);
      NSArray *kinds = [[DBDict([entry objectForKey:@"streams"]) allKeys]
          sortedArrayUsingSelector:@selector(compare:)];
      [fields addObject:[pages page:source detail:[kinds componentsJoinedByString:@", "]
                              build:^DBEditPage *{ return [weakSelf mediaSourcePage:source]; }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.media_hint"];
    section.onDelete = ^BOOL(NSInteger index) {
      NSArray *now = [[DBDict([weakSelf at:@"media_sources"]) allKeys]
          sortedArrayUsingSelector:@selector(compare:)];
      if (index >= (NSInteger)[now count]) return NO;
      return [weakSelf deleteKey:[@"media_sources." stringByAppendingString:
                                     [now objectAtIndex:(NSUInteger)index]]];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"editor.camera_name"] value:@"" placeholder:@"front_camera"
               keyboard:UIKeyboardTypeASCIICapable secure:NO then:^(NSString *text) {
      DBSettingsPages *inner = weakSelf;
      NSString *source = DBTrim(text);
      if (!DBSafeId(source)) {
        [editor showMessage:[inner t:@"editor.id_hint"]];
        return;
      }
      [editor promptTitle:@"MJPEG URL" value:@"http://" placeholder:@"http://192.0.2.20/live.mjpeg"
                 keyboard:UIKeyboardTypeURL secure:NO then:^(NSString *url) {
        DBSettingsPages *again = weakSelf;
        NSDictionary *entry = @{ @"schema_version" : @1, @"kind" : @"ip_camera",
                                 @"streams" : @{ @"mjpeg" : @{ @"url" : DBTrim(url) } } };
        if ([again setKey:[@"media_sources." stringByAppendingString:source] value:entry]) {
          [editor reloadPage];
          [editor pushPage:[again mediaSourcePage:source]];
        }
      }];
    }];
  };
  return page;
}

// A media source is replaced as one complete definition (Core rejects partial
// writes), so every edit rewrites the whole entry.
- (BOOL)updateSource:(NSString *)source stream:(NSString *)stream url:(NSString *)url {
  NSString *key = [@"media_sources." stringByAppendingString:source];
  NSMutableDictionary *entry = [DBDict([self at:key]) mutableCopy];
  NSMutableDictionary *streams = [DBDict([entry objectForKey:@"streams"]) mutableCopy];
  NSString *value = DBTrim(url ?: @"");
  if ([value length] == 0) {
    [streams removeObjectForKey:stream];
  } else if ([stream isEqualToString:@"h264"]) {
    [streams setObject:@{ @"url" : value, @"transport" : @"tcp", @"profile" : @"baseline" }
                forKey:stream];
  } else {
    [streams setObject:@{ @"url" : value } forKey:stream];
  }
  if ([streams count] == 0) return NO;
  [entry setObject:@1 forKey:@"schema_version"];
  [entry setObject:@"ip_camera" forKey:@"kind"];
  [entry setObject:streams forKey:@"streams"];
  return [self setKey:key value:entry];
}

- (DBEditPage *)mediaSourcePage:(NSString *)source {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *key = [@"media_sources." stringByAppendingString:source];
  return [DBEditPage title:source build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *streams = DBDict([pages at:[key stringByAppendingString:@".streams"]]);
    NSMutableArray *fields = [NSMutableArray array];
    for (NSArray *stream in @[ @[ @"mjpeg", @"MJPEG (http/https)" ],
                               @[ @"snapshot", @"Snapshot JPEG (http/https)" ],
                               @[ @"h264", @"H.264 (rtsp, TCP, Baseline)" ] ]) {
      NSString *name = [stream objectAtIndex:0];
      DBEditField *field = [DBEditField kind:DBEditKindText title:[stream objectAtIndex:1]
          value:[DBConfigUtil str:DBDict([streams objectForKey:name]) path:@"url"] ?: @""];
      field.keyboard = UIKeyboardTypeURL;
      field.onChange = ^BOOL(id value) {
        return [weakSelf updateSource:source stream:name url:[value description]];
      };
      [fields addObject:field];
    }
    DBEditSection *urls = [DBEditSection title:[pages t:@"editor.streams"] fields:fields];
    urls.footer = [pages t:@"editor.media_url_hint"];
    // The camera's own login is a secret; the URL must never carry it.
    DBEditField *credential = [DBEditField kind:DBEditKindSecret
                                          title:[pages t:@"editor.camera_credential"]
        value:[NSNumber numberWithBool:[pages hasSecretAt:[key stringByAppendingString:@".secret_ref"]]]];
    credential.placeholder = @"user:password";
    credential.onChange = ^BOOL(id value) {
      DBSettingsPages *inner = weakSelf;
      NSString *secret = [value description];
      NSMutableDictionary *entry = [DBDict([inner at:key]) mutableCopy];
      if ([secret length] == 0) {
        [entry removeObjectForKey:@"secret_ref"];
        return [inner setKey:key value:entry];
      }
      NSString *name = [NSString stringWithFormat:@"media.%@.%@", source, DBRandomHex(4) ?: @"x"];
      if (![inner->_core storeSecret:name value:secret]) {
        [inner toast:@"editor.secret_store_failed"];
        return NO;
      }
      [entry setObject:[@"secret:" stringByAppendingString:name] forKey:@"secret_ref"];
      return [inner setKey:key value:entry];
    };
    DBEditField *remove = [pages action:[pages t:@"editor.delete"] block:^{
      if ([weakSelf deleteKey:key]) [editor popPage];
    }];
    remove.destructive = YES;
    return @[ urls, [DBEditSection title:nil fields:@[ credential ]],
              [DBEditSection title:nil fields:@[ remove ]] ];
  }];
}

#pragma mark - buildings, doors and households

- (DBEditPage *)labelledMapPage:(NSString *)root title:(NSString *)title prefix:(NSString *)prefix
                       addTitle:(NSString *)addTitle extra:(NSArray *(^)(NSString *base))extra {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:title build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *map = DBDict([pages at:root]);
    NSArray *ids = [DBConfigUtil sortedByOrder:map];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *entryId in ids) {
      NSString *base = [NSString stringWithFormat:@"%@.%@", root, entryId];
      [fields addObject:[pages page:[pages label:[map objectForKey:entryId] fallback:entryId]
                             detail:entryId build:^DBEditPage *{
        DBSettingsPages *inner = weakSelf;
        return [DBEditPage title:[inner label:[inner at:base] fallback:entryId] build:^NSArray *{
          DBSettingsPages *deep = weakSelf;
          NSMutableArray *sections = [NSMutableArray arrayWithObject:
              [DBEditSection title:[deep t:@"editor.label"]
                            fields:[deep localizedFields:[base stringByAppendingString:@".label"]]]];
          NSArray *more = extra ? extra(base) : nil;
          if ([more count] > 0) [sections addObject:[DBEditSection title:nil fields:more]];
          DBEditField *remove = [deep action:[deep t:@"editor.delete"] block:^{
            if ([weakSelf deleteKey:base]) [editor popPage];
          }];
          remove.destructive = YES;
          [sections addObject:[DBEditSection title:nil fields:@[ remove ]]];
          return sections;
        }];
      }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.onDelete = ^BOOL(NSInteger index) {
      NSArray *now = [DBConfigUtil sortedByOrder:DBDict([weakSelf at:root])];
      if (index >= (NSInteger)[now count]) return NO;
      return [weakSelf deleteKey:[NSString stringWithFormat:@"%@.%@", root,
                                                            [now objectAtIndex:(NSUInteger)index]]];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    [editor promptTitle:addTitle value:@"" placeholder:nil keyboard:UIKeyboardTypeDefault
                 secure:NO then:^(NSString *text) {
      DBSettingsPages *inner = weakSelf;
      NSString *label = DBTrim(text);
      if (!inner || [label length] == 0) return;
      NSString *entryId = [inner newIdWithPrefix:prefix in:root];
      if ([inner setKey:[NSString stringWithFormat:@"%@.%@", root, entryId]
                  value:@{ @"label" : @{ [inner lang] : label } }])
        [editor reloadPage];
    }];
  };
  return page;
}

- (DBEditPage *)placesPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"editor.places"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *doors = [pages page:[pages t:@"editor.doors"]
        detail:[NSString stringWithFormat:@"%lu", (unsigned long)[DBDict([pages at:@"doors"]) count]]
         build:^DBEditPage *{
      DBSettingsPages *inner = weakSelf;
      return [inner labelledMapPage:@"doors" title:[inner t:@"editor.doors"] prefix:@"d_"
                           addTitle:[inner t:@"editor.new_door"]
                              extra:^NSArray *(NSString *base) {
        DBSettingsPages *deep = weakSelf;
        NSMutableArray *buildings = [NSMutableArray arrayWithObject:@[ @"", @"—" ]];
        NSDictionary *map = DBDict([deep at:@"buildings"]);
        for (NSString *building in [DBConfigUtil sortedByOrder:map])
          [buildings addObject:@[ building, [deep label:[map objectForKey:building]
                                                 fallback:building] ]];
        DBEditField *building = [deep choice:[deep t:@"editor.building"]
                                         key:[base stringByAppendingString:@".building"] def:@""
                                     choices:buildings];
        NSString *key = [base stringByAppendingString:@".building"];
        building.onChange = ^BOOL(id value) {
          return [value length] == 0 ? [weakSelf deleteKey:key] : [weakSelf setKey:key value:value];
        };
        return @[ building ];
      }];
    }];
    DBEditField *buildings = [pages page:[pages t:@"editor.buildings"]
        detail:[NSString stringWithFormat:@"%lu", (unsigned long)[DBDict([pages at:@"buildings"]) count]]
         build:^DBEditPage *{
      DBSettingsPages *inner = weakSelf;
      return [inner labelledMapPage:@"buildings" title:[inner t:@"editor.buildings"] prefix:@"b_"
                           addTitle:[inner t:@"editor.new_building"] extra:nil];
    }];
    DBEditField *households = [pages page:[pages t:@"editor.households"]
        detail:[NSString stringWithFormat:@"%lu", (unsigned long)[DBDict([pages at:@"households"]) count]]
         build:^DBEditPage *{ return [weakSelf householdsPage]; }];
    DBEditField *presets = [pages page:[pages t:@"notice.presets"] detail:nil
        build:^DBEditPage *{ return [weakSelf noticePresetsPage]; }];
    return @[ [DBEditSection title:nil fields:@[ buildings, doors, households, presets ]] ];
  }];
}

#pragma mark - devices

- (DBEditPage *)devicesPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"admin.devices"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *devices = DBDict([pages at:@"devices"]);
    NSDictionary *status = [pages->_core status];
    NSMutableArray *fields = [NSMutableArray array];
    NSArray *ids = [[devices allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *device in ids) {
      if (!DBSafeId(device)) continue;
      NSDictionary *entry = DBDict([devices objectForKey:device]);
      NSString *name = [DBConfigUtil str:entry path:@"name"] ?: device;
      NSString *role = [DBConfigUtil str:entry path:@"role"] ?: @"";
      BOOL me = [device isEqualToString:pages.nodeId];
      NSDictionary *peer = [DBConfigUtil findPeer:status nodeId:device];
      NSString *state = me ? [pages t:@"editor.this_device"]
          : (peer && [DBConfigUtil boolVal:peer path:@"alive" def:YES] ? [pages t:@"editor.online"]
                                                                      : [pages t:@"editor.offline"]);
      NSString *roleLabel = [role isEqualToString:@"door_station"] ? [pages t:@"admin.role_door"]
          : ([role isEqualToString:@"indoor_panel"] ? [pages t:@"admin.role_indoor"] : role);
      [fields addObject:[pages page:name
                             detail:[NSString stringWithFormat:@"%@ · %@", roleLabel, state]
                              build:^DBEditPage *{ return [weakSelf devicePage:device]; }]];
    }
    return @[ [DBEditSection title:nil fields:fields] ];
  }];
}

- (DBEditPage *)devicePage:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *base = [@"devices." stringByAppendingString:device];
  return [DBEditPage title:[DBConfigUtil str:[self cfg] path:[base stringByAppendingString:@".name"]] ?: device
                     build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *name = [pages text:[pages t:@"settings.device_name"]
                                key:[base stringByAppendingString:@".name"]];
    NSString *role = [DBConfigUtil str:[pages cfg] path:[base stringByAppendingString:@".role"]] ?: @"";
    DBEditField *roleField = [DBEditField kind:DBEditKindInfo title:[pages t:@"settings.device_role"]
        value:([role isEqualToString:@"door_station"] ? [pages t:@"admin.role_door"]
                                                      : [pages t:@"admin.role_indoor"])];
    NSMutableArray *fields = [NSMutableArray arrayWithObjects:name, roleField, nil];
    if ([role isEqualToString:@"door_station"]) {
      DBEditField *door = [pages choice:[pages t:@"settings.device_door"]
                                    key:[base stringByAppendingString:@".door"] def:@""
                                choices:[pages doorChoices]];
      [fields addObject:door];
    }
    [fields addObject:[DBEditField kind:DBEditKindInfo title:@"ID" value:device]];
    DBEditSection *main = [DBEditSection title:nil fields:fields];
    main.footer = [pages t:@"editor.role_on_device"];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:main];
    if (![device isEqualToString:pages.nodeId]) {
      DBEditField *remove = [pages action:[pages t:@"editor.remove_device"] block:^{
        DBSettingsPages *inner = weakSelf;
        int status = [inner->_core removeDeviceV2:device];
        if (status == -100) {
          [inner->_core removeDevice:device];
          status = 0;
        }
        if (status == DBAdminRequiredResult) {
          [inner->_router requestPinThen:^{
            DBSettingsPages *strong = weakSelf;
            if (strong && [strong->_core removeDeviceV2:device] == 0) [editor popPage];
          }];
          return;
        }
        if (status == 0) {
          [inner toast:@"settings.saved"];
          [editor popPage];
        } else {
          [inner toast:@"settings.save_failed"];
        }
      }];
      remove.destructive = YES;
      [sections addObject:[DBEditSection title:nil fields:@[ remove ]]];
    }
    return sections;
  }];
}

#pragma mark - wording overrides

- (DBEditPage *)wordingPage {
  __weak DBSettingsPages *weakSelf = self;
  DBEditPage *page = [DBEditPage title:[self t:@"editor.wording"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *builtin = DBGeneratedStringsForLanguage([pages lang]);
    NSDictionary *overrides = DBDict([pages at:@"i18n_overrides"]);
    NSDictionary *mine = DBDict([overrides objectForKey:[pages lang]]);
    NSMutableSet *changed = [NSMutableSet set];
    for (NSString *lang in kDBLangs())
      [changed addObjectsFromArray:[DBDict([overrides objectForKey:lang]) allKeys]];
    NSMutableArray *edited = [NSMutableArray array];
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *key in [[builtin allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      NSString *text = [mine objectForKey:key] ?: [builtin objectForKey:key];
      DBEditField *field = [pages page:key detail:[text description]
                                 build:^DBEditPage *{ return [weakSelf wordPage:key]; }];
      if ([changed containsObject:key]) [edited addObject:field];
      else [all addObject:field];
    }
    NSMutableArray *sections = [NSMutableArray array];
    if ([edited count] > 0)
      [sections addObject:[DBEditSection title:[pages t:@"editor.edited"] fields:edited]];
    DBEditSection *rest = [DBEditSection title:[pages t:@"editor.all_wording"] fields:all];
    rest.footer = [pages t:@"editor.wording_hint"];
    [sections addObject:rest];
    return sections;
  }];
  page.searchable = YES;
  return page;
}

// i18n keys contain dots, so each language's override map is written whole.
- (BOOL)setOverride:(NSString *)key lang:(NSString *)lang text:(NSString *)text {
  NSString *mapKey = [@"i18n_overrides." stringByAppendingString:lang];
  NSMutableDictionary *map = [DBDict([self at:mapKey]) mutableCopy];
  if ([text length] == 0) [map removeObjectForKey:key];
  else [map setObject:text forKey:key];
  return [map count] == 0 ? [self deleteKey:mapKey] : [self setKey:mapKey value:map];
}

- (DBEditPage *)wordPage:(NSString *)key {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:key build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *overrides = DBDict([pages at:@"i18n_overrides"]);
    NSMutableArray *fields = [NSMutableArray array];
    BOOL any = NO;
    for (NSString *lang in kDBLangs()) {
      NSString *builtin = [DBGeneratedStringsForLanguage(lang) objectForKey:key] ?: @"";
      NSString *override = [DBDict([overrides objectForKey:lang]) objectForKey:key];
      if (override) any = YES;
      DBEditField *field = [DBEditField kind:DBEditKindText
          title:[NSString stringWithFormat:@"%@%@", [DBTexts langDisplayName:lang],
                    override ? @" ✎" : @""]
          value:[override description] ?: builtin];
      field.placeholder = builtin;
      field.onChange = ^BOOL(id value) {
        NSString *text = [value description];
        // Typing the built-in wording back is the same as resetting it.
        if ([text isEqualToString:builtin]) text = @"";
        if ([text length] > 0 && [builtin length] > 0 &&
            ![DBPlaceholders(text) isEqualToSet:DBPlaceholders(builtin)]) {
          [editor showMessage:[NSString stringWithFormat:@"%@\n%@", [weakSelf t:@"editor.placeholder_hint"],
              [[DBPlaceholders(builtin) allObjects] componentsJoinedByString:@" "]]];
          return NO;
        }
        return [weakSelf setOverride:key lang:lang text:text];
      };
      [fields addObject:field];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.placeholder_hint"];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:section];
    if (any) {
      DBEditField *reset = [pages action:[pages t:@"editor.reset"] block:^{
        DBSettingsPages *inner = weakSelf;
        NSMutableArray *ops = [NSMutableArray array];
        NSDictionary *now = DBDict([inner at:@"i18n_overrides"]);
        for (NSString *lang in kDBLangs()) {
          NSMutableDictionary *map = [DBDict([now objectForKey:lang]) mutableCopy];
          if ([map objectForKey:key] == nil) continue;
          [map removeObjectForKey:key];
          NSString *mapKey = [@"i18n_overrides." stringByAppendingString:lang];
          [ops addObject:[map count] ? [inner set:mapKey value:map] : [inner del:mapKey]];
        }
        if ([inner commit:ops]) [editor reloadPage];
      }];
      reset.destructive = YES;
      [sections addObject:[DBEditSection title:nil fields:@[ reset ]]];
    }
    return sections;
  }];
}

#pragma mark - theme

- (NSString *)assetLabel:(NSString *)hash {
  NSDictionary *asset = DBDict([self at:[@"assets." stringByAppendingString:hash ?: @""]]);
  NSString *label = [DBConfigUtil str:asset path:@"label"];
  if ([label length] > 0) return label;
  return [hash length] >= 8 ? [hash substringToIndex:8] : (hash ?: @"");
}

- (DBEditField *)colorField:(NSString *)title key:(NSString *)key fallback:(NSString *)fallback {
  NSString *hex = [DBConfigUtil str:[self cfg] path:key];
  DBEditField *field = [DBEditField kind:DBEditKindColor title:title value:hex ?: fallback ?: @""];
  field.detail = hex ?: [self t:@"editor.automatic"];
  UIColor *color = [DBConfigUtil parseHexColor:hex ?: fallback];
  if (color) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(24, 24), NO, 0);
    [color setFill];
    UIRectFill(CGRectMake(0, 0, 24, 24));
    field.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
  }
  __weak DBSettingsPages *weakSelf = self;
  field.onChange = ^BOOL(id value) { return [weakSelf setKey:key value:value]; };
  return field;
}

- (DBEditPage *)themeScopePage:(BOOL)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *prefix = device ? [NSString stringWithFormat:@"devices.%@.local.theme", _nodeId]
                            : @"display.theme";
  return [DBEditPage title:[self t:(device ? @"editor.this_device" : @"editor.all_devices")]
                     build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSString *colorKey = [prefix stringByAppendingString:@".bg_color"];
    NSString *imageKey = [prefix stringByAppendingString:@".bg_image"];
    DBEditField *color = [pages colorField:[pages t:@"settings.theme_bg"] key:colorKey
                                  fallback:(device ? [DBConfigUtil str:[pages cfg]
                                                             path:@"display.theme.bg_color"] : nil)];
    NSString *image = [DBConfigUtil str:[pages cfg] path:imageKey];
    DBEditField *choose = [pages action:[pages t:@"editor.choose_photo"] block:^{
      [weakSelf pickImageForKey:imageKey];
    }];
    NSMutableArray *imageFields = [NSMutableArray arrayWithObject:choose];
    if ([image length] > 0) {
      [imageFields insertObject:[DBEditField kind:DBEditKindInfo title:[pages t:@"editor.current_image"]
                                            value:[pages assetLabel:image]] atIndex:0];
      DBEditField *clear = [pages action:[pages t:@"editor.remove_image"] block:^{
        if ([weakSelf deleteKey:imageKey]) [editor reloadPage];
      }];
      clear.destructive = YES;
      [imageFields addObject:clear];
    }
    NSMutableArray *sections = [NSMutableArray arrayWithObjects:
        [DBEditSection title:nil fields:@[ color ]],
        [DBEditSection title:[pages t:@"editor.background_image"] fields:imageFields], nil];
    NSMutableArray *inks = [NSMutableArray array];
    for (NSString *region in @[ @"clock", @"date", @"status_line", @"hint", @"tile_label" ]) {
      NSString *key = [NSString stringWithFormat:@"%@.ink_override.%@", prefix, region];
      [inks addObject:[pages page:[pages t:[@"editor.region_" stringByAppendingString:region]]
                           detail:[DBConfigUtil str:[pages cfg] path:key] ?: [pages t:@"editor.automatic"]
                            build:^DBEditPage *{
        DBSettingsPages *inner = weakSelf;
        return [DBEditPage title:[inner t:[@"editor.region_" stringByAppendingString:region]]
                           build:^NSArray *{
          DBSettingsPages *deep = weakSelf;
          DBEditField *ink = [deep colorField:[deep t:@"editor.ink"] key:key fallback:nil];
          DBEditField *automatic = [deep action:[deep t:@"editor.automatic"] block:^{
            if ([weakSelf deleteKey:key]) [editor reloadPage];
          }];
          DBEditSection *section = [DBEditSection title:nil fields:@[ ink, automatic ]];
          section.footer = [deep t:@"editor.ink_hint"];
          return @[ section ];
        }];
      }]];
    }
    [sections addObject:[DBEditSection title:[pages t:@"editor.ink_overrides"] fields:inks]];
    if (device) {
      DBEditField *reset = [pages action:[pages t:@"editor.use_cluster_theme"] block:^{
        if ([weakSelf deleteKey:prefix]) [editor reloadPage];
      }];
      reset.destructive = YES;
      [sections addObject:[DBEditSection title:nil fields:@[ reset ]]];
    }
    return sections;
  }];
}

- (DBEditPage *)themePage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"settings.theme_bg"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    [fields addObject:[pages page:[pages t:@"editor.all_devices"]
                           detail:[DBConfigUtil str:[pages cfg] path:@"display.theme.bg_color"] ?: @""
                            build:^DBEditPage *{ return [weakSelf themeScopePage:NO]; }]];
    if ([pages.nodeId length] > 0)
      [fields addObject:[pages page:[pages t:@"editor.this_device"]
          detail:[DBConfigUtil str:[pages cfg] path:[NSString stringWithFormat:
                     @"devices.%@.local.theme.bg_color", pages.nodeId]] ?: [pages t:@"editor.inherited"]
           build:^DBEditPage *{ return [weakSelf themeScopePage:YES]; }]];
    [fields addObject:[pages page:[pages t:@"editor.images"] detail:nil
                            build:^DBEditPage *{ return [weakSelf assetsPage:@"image/"]; }]];
    return @[ [DBEditSection title:nil fields:fields] ];
  }];
}

// The asset ledger filtered by MIME prefix; deleting removes the ledger entry.
- (DBEditPage *)assetsPage:(NSString *)typePrefix {
  __weak DBSettingsPages *weakSelf = self;
  NSString *title = [typePrefix hasPrefix:@"image"] ? [self t:@"editor.images"]
                                                    : [self t:@"editor.sounds"];
  return [DBEditPage title:title build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *assets = DBDict([pages at:@"assets"]);
    NSMutableArray *hashes = [NSMutableArray array];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *hash in [[assets allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      NSDictionary *asset = DBDict([assets objectForKey:hash]);
      if (![[DBConfigUtil str:asset path:@"type"] hasPrefix:typePrefix]) continue;
      [hashes addObject:hash];
      long long size = [DBConfigUtil longLongVal:asset path:@"size" def:0];
      [fields addObject:[DBEditField kind:DBEditKindInfo title:[pages assetLabel:hash]
          value:[NSString stringWithFormat:@"%@ · %lld KB", [DBConfigUtil str:asset path:@"type"] ?: @"",
                                           size / 1024]]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.assets_hint"];
    section.onDelete = ^BOOL(NSInteger index) {
      DBSettingsPages *inner = weakSelf;
      if (index >= (NSInteger)[hashes count]) return NO;
      NSDictionary *result = [inner->_core removeAsset:[hashes objectAtIndex:(NSUInteger)index]];
      if ([[result objectForKey:@"ok"] boolValue]) {
        [inner toast:@"settings.saved"];
        return YES;
      }
      [inner->_editor showMessage:[NSString stringWithFormat:@"%@\n%@",
          [inner t:@"settings.save_failed"], [DBConfigUtil evStr:result key:@"err"] ?: @""]];
      return NO;
    };
    return @[ section ];
  }];
}

- (void)pickImageForKey:(NSString *)key {
  if (![DBCoreBridge supportsAssets]) {
    [self toast:@"editor.core_too_old"];
    return;
  }
  // The library is shown in a popover, which only exists on the iPad idiom; modal
  // presentation is not available to these screens.
  if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad ||
      ![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
    [self toast:@"editor.no_photos"];
    return;
  }
  _pickerScope = [key copy];
  _picker = [[UIImagePickerController alloc] init];
  _picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  _picker.mediaTypes = @[ @"public.image" ];  // kUTTypeImage, without linking MobileCoreServices
  _picker.delegate = self;
  // An iPad presents the photo library in a popover.
  _popover = [[UIPopoverController alloc] initWithContentViewController:_picker];
  _popover.delegate = self;
  UIView *anchor = _editor;
  CGRect rect = CGRectMake(CGRectGetMidX(anchor.bounds) - 1, 80, 2, 2);
  [_popover presentPopoverFromRect:rect inView:anchor permittedArrowDirections:UIPopoverArrowDirectionUp
                          animated:YES];
}

- (void)finishPicker {
  [_popover dismissPopoverAnimated:YES];
  _popover = nil;
  _picker.delegate = nil;
  _picker = nil;
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController {
  _popover = nil;
  _picker.delegate = nil;
  _picker = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
  [self finishPicker];
}

// Scaled to at most 1600 px on the long edge and re-encoded as JPEG so the
// upload stays well below Core's 3 MiB asset limit.
static NSData *DBJpegForUpload(UIImage *image) {
  CGSize size = image.size;
  CGFloat scale = MIN(1.0, 1600.0 / MAX(size.width, size.height));
  CGSize target = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
  UIGraphicsBeginImageContextWithOptions(target, YES, 1);
  [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
  UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  NSData *data = nil;
  for (CGFloat quality = 0.85; quality > 0.3; quality -= 0.15) {
    data = UIImageJPEGRepresentation(scaled, quality);
    if ([data length] < 2.8 * 1024 * 1024) break;
  }
  return data;
}

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary *)info {
  UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
  NSString *key = _pickerScope;
  [self finishPicker];
  if (image == nil || [key length] == 0) return;
  [_editor showMessage:[self t:@"editor.uploading"]];
  __weak DBSettingsPages *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSData *jpeg = DBJpegForUpload(image);
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf uploadAsset:jpeg type:@"image/jpeg" label:@"photo.jpg" key:key];
    });
  });
}

- (void)uploadAsset:(NSData *)data type:(NSString *)type label:(NSString *)label key:(NSString *)key {
  if ([data length] == 0) {
    [self toast:@"settings.save_failed"];
    return;
  }
  NSDictionary *result = [_core addAsset:data type:type label:label];
  NSString *hash = [DBConfigUtil evStr:result key:@"hash"];
  if (![[result objectForKey:@"ok"] boolValue] || [hash length] == 0) {
    NSString *err = [DBConfigUtil evStr:result key:@"err"] ?: @"";
    if ([err isEqualToString:@"admin_required"]) {
      __weak DBSettingsPages *weakSelf = self;
      [_router requestPinThen:^{ [weakSelf uploadAsset:data type:type label:label key:key]; }];
      return;
    }
    [_editor showMessage:[NSString stringWithFormat:@"%@\n%@", [self t:@"settings.save_failed"], err]];
    return;
  }
  NSString *value = [type hasPrefix:@"audio/"] ? [@"asset:" stringByAppendingString:hash] : hash;
  if ([key length] == 0 || [self setKey:key value:value]) [_editor reloadPage];
}

#pragma mark - sounds

- (DBEditPage *)soundsPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"editor.sounds"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *ringtone = [pages choice:[pages t:@"prefs.ringtone"] key:@"ui.ringtone"
                                      def:@"school_chime" choices:[pages soundChoices]];
    DBEditField *alarm = [pages choice:[pages t:@"prefs.sos_sound"] key:@"emergency.alarm_sound"
                                   def:@"siren1" choices:[pages soundChoices]];
    BOOL recording = pages->_recorder.recording;
    DBEditField *record = [pages action:[pages t:(recording ? @"editor.stop_recording"
                                                            : @"editor.record_sound")]
                                  block:^{
      DBSettingsPages *inner = weakSelf;
      if (inner->_recorder.recording) [inner stopRecording];
      else [inner startRecording];
    }];
    DBEditSection *add = [DBEditSection title:[pages t:@"prefs.sound_upload"] fields:@[ record ]];
    add.footer = [pages t:@"editor.record_hint"];
    DBEditField *library = [pages page:[pages t:@"editor.sounds"] detail:nil
                                 build:^DBEditPage *{ return [weakSelf assetsPage:@"audio/"]; }];
    return @[ [DBEditSection title:nil fields:@[ ringtone, alarm ]], add,
              [DBEditSection title:nil fields:@[ library ]] ];
  }];
}

// Recording on the device itself: 16 kHz mono 16-bit WAV, at most 60 s
// (about 1.9 MB, inside Core's 3 MiB asset limit).
- (void)startRecording {
  if (![DBCoreBridge supportsAssets]) {
    [self toast:@"editor.core_too_old"];
    return;
  }
  AVAudioSession *session = [AVAudioSession sharedInstance];
  // Calls set their own category when they start; the previous one is put
  // back when the recording ends.
  _savedAudioCategory = [session.category copy];
  [session setCategory:AVAudioSessionCategoryPlayAndRecord error:NULL];
  [session setActive:YES error:NULL];
  if (!session.inputIsAvailable) {
    [self toast:@"editor.no_microphone"];
    return;
  }
  _recordPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"doorbell-recording.wav"];
  [[NSFileManager defaultManager] removeItemAtPath:_recordPath error:NULL];
  NSDictionary *settings = @{
    AVFormatIDKey : [NSNumber numberWithInt:kAudioFormatLinearPCM],
    AVSampleRateKey : @16000.0,
    AVNumberOfChannelsKey : @1,
    AVLinearPCMBitDepthKey : @16,
    AVLinearPCMIsBigEndianKey : @NO,
    AVLinearPCMIsFloatKey : @NO,
  };
  NSError *error = nil;
  _recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:_recordPath]
                                          settings:settings error:&error];
  _recorder.delegate = self;
  if (_recorder == nil || ![_recorder recordForDuration:60]) {
    _recorder = nil;
    [self toast:@"editor.no_microphone"];
    return;
  }
  [self toast:@"editor.recording"];
  [_editor reloadPage];
}

- (void)stopRecording {
  [_recorder stop];
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
  NSString *path = _recordPath;
  _recorder = nil;
  if ([_savedAudioCategory length] > 0)
    [[AVAudioSession sharedInstance] setCategory:_savedAudioCategory error:NULL];
  _savedAudioCategory = nil;
  [_editor reloadPage];
  NSData *data = flag ? [NSData dataWithContentsOfFile:path] : nil;
  [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
  if ([data length] < 1024) {
    [self toast:@"settings.save_failed"];
    return;
  }
  __weak DBSettingsPages *weakSelf = self;
  [_editor promptTitle:[self t:@"editor.sound_name"] value:@"" placeholder:@"chime.wav"
              keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
    NSString *label = [DBTrim(text) length] ? DBTrim(text) : @"recording.wav";
    [weakSelf uploadAsset:data type:@"audio/wav" label:label key:nil];
  }];
}

#pragma mark - configuration export and import

- (DBEditPage *)configTransferPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"editor.config_transfer"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *export = [pages action:[pages t:@"editor.export_clipboard"] block:^{
      DBSettingsPages *inner = weakSelf;
      NSDictionary *snapshot = [inner->_core configSnapshot];
      if (snapshot == nil) {
        [inner toast:@"editor.core_too_old"];
        return;
      }
      NSDictionary *document = @{ @"schema_version" : @2,
                                  @"config" : [snapshot objectForKey:@"config"] ?: @{} };
      NSData *data = [NSJSONSerialization dataWithJSONObject:document
                                                     options:NSJSONWritingPrettyPrinted error:NULL];
      NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
      if ([json length] == 0) {
        [inner toast:@"settings.save_failed"];
        return;
      }
      [UIPasteboard generalPasteboard].string = json;
      [inner->_editor showMessage:[inner->_texts t:@"editor.exported",
          [NSString stringWithFormat:@"%lu", (unsigned long)([data length] / 1024 + 1)], nil]];
    }];
    DBEditField *import = [pages action:[pages t:@"editor.import_clipboard"] block:^{
      [weakSelf importFromClipboard];
    }];
    import.confirm = YES;
    DBEditSection *section = [DBEditSection title:nil fields:@[ export, import ]];
    section.footer = [pages t:@"editor.config_transfer_hint"];
    return @[ section ];
  }];
}

- (void)importFromClipboard {
  NSString *text = [UIPasteboard generalPasteboard].string;
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![parsed isKindOfClass:[NSDictionary class]]) {
    [self toast:@"editor.clipboard_not_config"];
    return;
  }
  NSDictionary *config = [[parsed objectForKey:@"config"] isKindOfClass:[NSDictionary class]]
      ? [parsed objectForKey:@"config"] : parsed;
  NSDictionary *snapshot = [_core configSnapshot];
  NSString *revision = [DBConfigUtil evStr:snapshot key:@"revision"];
  if ([revision length] == 0) {
    [self toast:@"editor.core_too_old"];
    return;
  }
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  [self withSession:^(DBAdminHttpSession *session) {
    DBSettingsPages *pages = weakSelf;
    if (!pages) return;
    NSDictionary *stage = [pages->_core configImport:@"stage"
        request:@{ @"schema_version" : @2, @"expected_revision" : revision,
                   @"document" : @{ @"schema_version" : @2, @"config" : config } }
        session:session.session csrf:session.csrf];
    NSString *token = [DBConfigUtil evStr:stage key:@"stage_token"];
    NSString *digest = [DBConfigUtil evStr:stage key:@"digest"];
    if (![[stage objectForKey:@"ok"] boolValue] || [token length] == 0 || [digest length] == 0) {
      [editor showMessage:[NSString stringWithFormat:@"%@\n%@", [pages t:@"settings.save_failed"],
          [DBConfigUtil evStr:stage key:@"error_code"] ?: [DBConfigUtil evStr:stage key:@"err"] ?: @""]];
      return;
    }
    NSDictionary *envelope = @{ @"schema_version" : @2, @"stage_token" : token, @"digest" : digest };
    NSDictionary *preflight = [pages->_core configImport:@"preflight" request:envelope
                                                 session:session.session csrf:session.csrf];
    if (![[preflight objectForKey:@"can_commit"] boolValue]) {
      [pages->_core configImport:@"cancel" request:envelope session:session.session
                            csrf:session.csrf];
      [editor showMessage:[pages t:@"editor.import_blocked"]];
      return;
    }
    NSInteger changes = [DBConfigUtil intVal:preflight path:@"expanded_leaf_mutations" def:0];
    [editor confirmTitle:[pages t:@"editor.import_clipboard"]
                 message:[pages->_texts t:@"editor.import_confirm",
                             [NSString stringWithFormat:@"%ld", (long)changes], nil]
                    then:^{
      DBSettingsPages *inner = weakSelf;
      NSMutableDictionary *commit = [envelope mutableCopy];
      [commit setObject:DBRandomHex(16) ?: @"" forKey:@"operation_id"];
      NSDictionary *result = [inner->_core configImport:@"commit" request:commit
                                                session:session.session csrf:session.csrf];
      [editor showMessage:[inner t:([[result objectForKey:@"ok"] boolValue] ? @"settings.saved"
                                                                            : @"settings.save_failed")]];
    }];
  }];
}

#pragma mark - administrator password

- (DBEditPage *)adminPasswordPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:[self t:@"editor.admin_password"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *change = [pages action:[pages t:@"editor.change_password"] block:^{
      DBSettingsPages *inner = weakSelf;
      [editor promptTitle:[inner t:@"editor.current_password"] value:@"" placeholder:nil
                 keyboard:UIKeyboardTypeASCIICapable secure:YES then:^(NSString *current) {
        [editor promptTitle:[weakSelf t:@"editor.new_password"] value:@"" placeholder:nil
                   keyboard:UIKeyboardTypeASCIICapable secure:YES then:^(NSString *next) {
          if ([next length] < 8) {
            [editor showMessage:[weakSelf t:@"editor.password_too_short"]];
            return;
          }
          [editor promptTitle:[weakSelf t:@"editor.repeat_password"] value:@"" placeholder:nil
                     keyboard:UIKeyboardTypeASCIICapable secure:YES then:^(NSString *again) {
            DBSettingsPages *deep = weakSelf;
            if (![again isEqualToString:next]) {
              [editor showMessage:[deep t:@"editor.password_mismatch"]];
              return;
            }
            int result = [deep->_core setAdminPasswordFrom:current to:next];
            deep->_http = nil;
            [editor showMessage:[deep t:(result == 0 ? @"editor.password_changed"
                                                     : @"editor.password_wrong")]];
          }];
        }];
      }];
    }];
    DBEditSection *section = [DBEditSection title:nil fields:@[ change ]];
    section.footer = [pages t:@"editor.password_hint"];
    return @[ section ];
  }];
}

@end
