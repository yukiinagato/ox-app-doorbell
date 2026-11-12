#import "DBSettingsPages.h"

#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>

#import "../Core/DBAdminHttpSession.h"
#import "../Core/DBBootConfig.h"
#import "../Core/DBCallHistoryModel.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBGeneratedStrings.h"
#import "../Core/DBSettingsLogic.h"
#import "../Core/DBTexts.h"
#import "../Core/DBUiTheme.h"
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
                               AVAudioRecorderDelegate, AVAudioPlayerDelegate,
                               UIPopoverControllerDelegate>
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
  NSMutableDictionary *_thumbnails;  // asset hash -> UIImage, main thread only
  AVAudioPlayer *_player;
  NSString *_playingHash;
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
  [self stopPlayback];
  _thumbnails = nil;
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

#pragma mark - shared helpers

- (NSDictionary *)statusNow {
  NSDictionary *status = [_core status];
  return [status isKindOfClass:[NSDictionary class]] ? status : @{};
}

- (DBEditField *)info:(NSString *)title value:(NSString *)value {
  return [DBEditField kind:DBEditKindInfo title:title value:value ?: @""];
}

// A destructive action; its confirmation names what is lost.
- (DBEditField *)danger:(NSString *)title message:(NSString *)message block:(void (^)(void))block {
  DBEditField *field = [self action:title block:block];
  field.destructive = YES;
  field.confirmMessage = message;
  return field;
}

// Says why a value was refused and redraws the row from the stored value.
- (BOOL)refuse:(NSString *)message {
  [_editor showMessage:message];
  __weak DBEditorView *editor = _editor;
  dispatch_async(dispatch_get_main_queue(), ^{ [editor reloadPage]; });
  return NO;
}

- (NSString *)roleLabel:(NSString *)role {
  if ([role isEqualToString:@"door_station"]) return [self t:@"admin.role_door"];
  if ([role isEqualToString:@"indoor_panel"]) return [self t:@"admin.role_indoor"];
  return role ?: @"";
}

- (NSString *)deviceName:(NSString *)device {
  NSString *name = [DBConfigUtil str:[self cfg]
                                path:[NSString stringWithFormat:@"devices.%@.name", device]];
  if ([name length] > 0) return name;
  return [device length] > 8 ? [device substringToIndex:8] : (device ?: @"");
}

// Paired devices as choices; role of nil lists every device.
- (NSArray *)deviceChoicesWithRole:(NSString *)role {
  NSMutableArray *choices = [NSMutableArray array];
  NSDictionary *devices = DBDict([self at:@"devices"]);
  for (NSString *device in [[devices allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    if (!DBSafeId(device)) continue;
    NSString *deviceRole = [DBConfigUtil str:DBDict([devices objectForKey:device]) path:@"role"];
    if (role && ![deviceRole isEqualToString:role]) continue;
    [choices addObject:@[ device, [self deviceName:device] ]];
  }
  return choices;
}

// The status entry of a device. This node answers from status.node when the peer list
// does not carry it.
- (NSDictionary *)peerFor:(NSString *)device status:(NSDictionary *)status {
  NSDictionary *peer = [DBConfigUtil findPeer:status nodeId:device];
  if (peer || ![device isEqualToString:_nodeId]) return peer;
  NSDictionary *node = DBDict([status objectForKey:@"node"]);
  NSMutableDictionary *me = [NSMutableDictionary dictionaryWithObject:@"alive" forKey:@"status"];
  for (NSString *key in @[ @"power", @"caps", @"tls_sha256", @"membership" ])
    if ([node objectForKey:key]) [me setObject:[node objectForKey:key] forKey:key];
  if ([node objectForKey:@"version"]) [me setObject:[node objectForKey:@"version"] forKey:@"sw"];
  return me;
}

- (NSString *)stateLabel:(NSString *)state {
  if ([state isEqualToString:@"online"]) return [self t:@"editor.online"];
  if ([state isEqualToString:@"suspect"]) return [self t:@"admin.peer_suspect"];
  return [self t:@"editor.offline"];
}

- (NSString *)batteryText:(NSDictionary *)health {
  NSNumber *battery = [health objectForKey:@"battery"];
  if (battery == nil) return nil;
  NSString *text = [_texts t:@"power.percent", [battery stringValue], nil];
  return [[health objectForKey:@"charging"] boolValue]
      ? [NSString stringWithFormat:@"%@ %@", text, [self t:@"power.charging"]] : text;
}

- (NSString *)healthText:(NSDictionary *)health {
  NSMutableArray *parts = [NSMutableArray arrayWithObject:
      [self stateLabel:[health objectForKey:@"state"]]];
  if ([health objectForKey:@"version"]) [parts addObject:[health objectForKey:@"version"]];
  NSString *battery = [self batteryText:health];
  if (battery) [parts addObject:battery];
  return [parts componentsJoinedByString:@" · "];
}

- (NSString *)membershipLabel:(NSDictionary *)peer {
  return [self t:[@"security.membership_" stringByAppendingString:
                     [DBSettingsLogic membershipState:peer]]];
}

// Requests to this device's own Core for the operations that have no C export. They ride
// the administrator session withSession: opens over loopback.
- (void)adminRequest:(NSString *)method path:(NSString *)path body:(NSDictionary *)body
                then:(void (^)(NSInteger status, NSDictionary *json))then {
  __weak DBSettingsPages *weakSelf = self;
  [self withSession:^(DBAdminHttpSession *session) {
    [session request:method path:path body:body
          completion:^(NSInteger status, NSDictionary *json) {
      DBSettingsPages *pages = weakSelf;
      if (!pages) return;
      if (status == 401 || status == 403) pages->_http = nil;
      if (status == 0) {
        [pages toast:@"editor.unreachable"];
        return;
      }
      then(status, json);
    }];
  }];
}

- (void)showFailure:(NSDictionary *)json {
  [_editor showMessage:[NSString stringWithFormat:@"%@\n%@", [self t:@"settings.save_failed"],
      [DBConfigUtil evStr:json key:@"err"] ?: @""]];
}

// A string value that keeps an explicit empty string, which DBConfigUtil str: folds to nil.
- (NSString *)rawString:(NSString *)key def:(NSString *)def {
  id value = [self at:key];
  return [value isKindOfClass:[NSString class]] ? value : def;
}

// Audio assets as @[hash, label]; quick-reply audio stores the bare hash.
- (NSArray *)audioAssetChoices {
  NSMutableArray *choices = [NSMutableArray array];
  NSDictionary *assets = DBDict([self at:@"assets"]);
  for (NSString *hash in [[assets allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    if (![[DBConfigUtil str:DBDict([assets objectForKey:hash]) path:@"type"] hasPrefix:@"audio/"])
      continue;
    [choices addObject:@[ hash, [self assetLabel:hash] ]];
  }
  return choices;
}

// None, the five event sounds, and every uploaded sound: the list the web admin offers for
// the launch, call, button, and update sounds.
- (NSArray *)eventSoundChoices {
  NSMutableArray *choices = [NSMutableArray arrayWithObject:@[ @"", [self t:@"sound.none"] ]];
  for (NSString *name in @[ @"outdoor_call_alert", @"button_click", @"school_chime",
                            @"indoor_update", @"title_display" ])
    [choices addObject:@[ name, [self t:[@"prefs.sound_" stringByAppendingString:name]] ]];
  for (NSArray *asset in [self audioAssetChoices])
    [choices addObject:@[ [@"asset:" stringByAppendingString:[asset objectAtIndex:0]],
                          [asset objectAtIndex:1] ]];
  return choices;
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
  if ([name isEqualToString:@"web_push"]) return [self webPushPage];
  if ([name isEqualToString:@"assets"]) return [self assetsPage:nil];
  if ([name isEqualToString:@"speech"]) return [self speechPage];
  if ([name isEqualToString:@"playback_policy"]) return [self playbackPolicyPage];
  if ([name isEqualToString:@"capabilities"]) return [self capabilitiesPage];
  if ([name isEqualToString:@"ui_elements"]) return [self uiElementsPage];
  if ([name isEqualToString:@"raw_config"]) return [self rawConfigPage];
  if ([name isEqualToString:@"logs"]) return [self logsPage];
  if ([name isEqualToString:@"other_devices"]) return [self otherDevicesPage];
  if ([name isEqualToString:@"cluster_security"]) return [self clusterSecurityPage];
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
    // A recorded clip per visitor language; without one the reply is spoken.
    NSArray *languages = DBArray([pages at:@"ui.languages"]);
    if ([languages count] == 0) languages = kDBLangs();
    NSMutableArray *clips = [NSMutableArray array];
    for (id candidate in languages) {
      if (![candidate isKindOfClass:[NSString class]] || !DBSafeId(candidate)) continue;
      NSString *lang = candidate;
      NSString *audioKey = [NSString stringWithFormat:@"%@.audio.%@", base, lang];
      NSMutableArray *choices = [NSMutableArray arrayWithObject:
          @[ @"", [pages t:@"admin.audio_none"] ]];
      [choices addObjectsFromArray:[pages audioAssetChoices]];
      DBEditField *clip = [DBEditField kind:DBEditKindChoice
                                      title:[DBTexts langDisplayName:lang]
                                      value:[DBConfigUtil str:[pages cfg] path:audioKey] ?: @""];
      clip.choices = choices;
      clip.onChange = ^BOOL(id value) {
        return [value length] == 0 ? [weakSelf deleteKey:audioKey]
                                   : [weakSelf setKey:audioKey value:value];
      };
      [clips addObject:clip];
    }
    DBEditField *remove = [pages danger:[pages t:@"editor.delete"]
                                message:[pages t:@"editor.reply_delete_confirm"] block:^{
      if ([weakSelf deleteKey:base]) [editor popPage];
    }];
    return @[ labels, [DBEditSection title:nil fields:@[ speak ]],
              [DBEditSection title:[pages t:@"prefs.reply_audio"] fields:clips],
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
    remove.confirmMessage = [pages t:@"editor.delete_confirm"];
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
    if ([whenType isEqualToString:@"device_offline"]) {
      NSString *devicesKey = [base stringByAppendingString:@".when.devices"];
      NSArray *chosen = DBArray([pages at:devicesKey]);
      DBEditField *devices = [DBEditField kind:DBEditKindMulti
                                         title:[pages t:@"admin.rule_devices"] value:chosen];
      devices.choices = [pages deviceChoicesWithRole:nil];
      devices.detail = [chosen count] == 0 ? [pages t:@"editor.all"] : nil;
      // No device selected is stored as "all", the value Core reads for every device.
      devices.onChange = ^BOOL(id value) {
        return [(NSArray *)value count] == 0 ? [weakSelf setKey:devicesKey value:@"all"]
                                            : [weakSelf setKey:devicesKey value:value];
      };
      [when addObject:devices];
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
    remove.confirmMessage = [pages t:@"editor.delete_confirm"];
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
        // Targets and chime devices are removed when nothing is chosen, which Core reads as
        // "no restriction"; the other lists keep their explicit empty value.
        if ([picked count] == 0 && ([path isEqualToString:@"devices"] ||
                                    [path hasPrefix:@"targets."]))
          stored = nil;
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
      DBEditField *targets = multi([pages t:@"admin.rule_devices"], @"devices",
                                   [pages deviceChoicesWithRole:nil], NO);
      if ([DBArray([action objectForKey:@"devices"]) count] == 0)
        targets.detail = [pages t:@"editor.all"];
      [fields addObject:targets];
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
      [fields addObject:multi([pages t:@"admin.alert_target_devices"], @"targets.devices",
                              [pages deviceChoicesWithRole:nil], YES)];
      id storedGroups = [DBConfigUtil dig:action path:@"targets.web_subscription_groups"];
      DBEditField *groups = [DBEditField kind:DBEditKindText
          title:[pages t:@"admin.alert_target_web_groups"]
          value:[storedGroups isKindOfClass:[NSArray class]]
                    ? [(NSArray *)storedGroups componentsJoinedByString:@", "]
                    : ([storedGroups isKindOfClass:[NSString class]] ? storedGroups : @"")];
      groups.keyboard = UIKeyboardTypeASCIICapable;
      groups.placeholder = @"all";
      groups.onChange = ^BOOL(id value) {
        // "all", or a list of group names separated by commas or spaces.
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *part in [[value description] componentsSeparatedByCharactersInSet:
                 [NSCharacterSet characterSetWithCharactersInString:@", "]])
          if ([part length] > 0) [names addObject:part];
        id stored = [names count] == 0 ? nil
            : (([names count] == 1 && [[names objectAtIndex:0] isEqualToString:@"all"])
                   ? (id)@"all" : (id)names);
        return [weakSelf updateAction:key index:index path:@"targets.web_subscription_groups"
                                value:stored];
      };
      [fields addObject:groups];
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
      DBEditField *volume = [DBEditField kind:DBEditKindNumber
          title:[pages t:@"admin.alert_volume"]
          value:[NSNumber numberWithInteger:[DBConfigUtil intVal:action path:@"presentation.volume"
                                                             def:100]]];
      volume.minimum = 0;
      volume.maximum = 100;
      volume.onChange = ^BOOL(id value) {
        return [weakSelf updateAction:key index:index path:@"presentation.volume" value:value];
      };
      [fields addObject:volume];
      // The alert's own colours. Core's defaults are shown until one is set; a combination
      // the alert text cannot be read on is refused, as in the web admin.
      NSDictionary *palette = @{ @"background" : @"#8F1010", @"foreground" : @"#FFFFFF",
                                 @"accent" : @"#FFD166" };
      for (NSString *part in @[ @"background", @"foreground", @"accent" ]) {
        NSString *path = [@"presentation." stringByAppendingString:part];
        DBEditField *color = [DBEditField kind:DBEditKindColor
            title:[pages t:[@"admin.alert_" stringByAppendingString:part]]
            value:[DBConfigUtil str:action path:path] ?: [palette objectForKey:part]];
        color.onChange = ^BOOL(id value) {
          DBSettingsPages *inner = weakSelf;
          NSMutableDictionary *next = [palette mutableCopy];
          for (NSString *other in palette) {
            NSString *stored = [DBConfigUtil str:action
                                            path:[@"presentation." stringByAppendingString:other]];
            if (stored) [next setObject:stored forKey:other];
          }
          [next setObject:[[value description] uppercaseString] forKey:part];
          NSString *background = [next objectForKey:@"background"];
          double text = [DBUiTheme contrastBetweenHex:[next objectForKey:@"foreground"]
                                               andHex:background];
          double accent = [DBUiTheme contrastBetweenHex:[next objectForKey:@"accent"]
                                                 andHex:background];
          if (text < 4.5 || accent < 3.0)
            return [inner refuse:[inner->_texts t:@"theme.low_contrast",
                [NSString stringWithFormat:@"%.1f", text < 4.5 ? text : accent], nil]];
          return [inner updateAction:key index:index path:path value:[next objectForKey:part]];
        };
        [fields addObject:color];
      }
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
  return [DBEditPage title:[self t:@"settings.telegram"] build:^NSArray *{
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
      DBEditField *disable = [pages danger:[pages t:@"editor.disable"]
                                   message:[pages t:@"editor.telegram_disable_confirm"] block:^{
        if ([weakSelf deleteKey:tokenKey]) [editor reloadPage];
      }];
      [sections addObject:[DBEditSection title:nil fields:@[ test, disable ]]];
    }
    // Core falls back to this offset for message times while no time zone is configured.
    NSString *offsetKey = @"integrations.tz_offset_min";
    DBEditField *offset = [DBEditField kind:DBEditKindText title:[pages t:@"admin.tz_offset"]
        value:[NSString stringWithFormat:@"%ld",
                  (long)[DBConfigUtil intVal:[pages cfg] path:offsetKey def:540]]];
    offset.keyboard = UIKeyboardTypeNumbersAndPunctuation;
    offset.onChange = ^BOOL(id value) {
      NSString *text = DBTrim([value description] ?: @"");
      NSScanner *scanner = [NSScanner scannerWithString:text];
      NSInteger minutes = 0;
      if (![scanner scanInteger:&minutes] || ![scanner isAtEnd] || minutes < -720 || minutes > 840)
        return [weakSelf refuse:@"-720 – 840"];
      return [weakSelf setKey:offsetKey value:[NSNumber numberWithInteger:minutes]];
    };
    DBEditSection *legacy = [DBEditSection title:nil fields:@[ offset ]];
    legacy.footer = [pages t:@"editor.tz_offset_hint"];
    [sections addObject:legacy];
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
    remove.confirmMessage = [pages t:@"editor.delete_confirm"];
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
  return [DBEditPage title:[self t:@"settings.page_sip"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *server = [pages text:[pages t:@"editor.server"] key:@"sip.server"];
    server.keyboard = UIKeyboardTypeURL;
    server.placeholder = @"10.0.1.5";
    DBEditField *port = [pages number:[pages t:@"editor.port"] key:@"sip.port" def:5060 min:1
                                  max:65535];
    DBEditField *transport = [pages choice:[pages t:@"editor.transport"] key:@"sip.transport"
                                       def:@"udp"
                                   choices:@[ @[ @"udp", @"UDP" ], @[ @"tcp", @"TCP" ],
                                              @[ @"tls", [pages t:@"settings.transport_tls"] ] ]];
    DBEditField *direct = [pages number:[pages t:@"editor.direct_port"] key:@"sip.direct_port"
                                    def:47190 min:1024 max:65535];
    DBEditField *srtp = [pages choice:[pages t:@"editor.srtp"] key:@"sip.srtp" def:@"optional"
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
    DBEditField *tls = [pages toggle:[pages t:@"settings.transport_tls"]
                                 key:[m stringByAppendingString:@"tls"] def:NO];
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
    DBEditSection *ha = [DBEditSection title:[pages t:@"settings.grp_ha"]
                                      fields:@[ language, sos, notice ]];
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
    revoke.confirmMessage = [pages t:@"editor.panel_revoke_confirm"];
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
      [editor promptTitle:[inner t:@"nset.camera_mjpeg"] value:@"http://" placeholder:@"http://192.0.2.20/live.mjpeg"
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
    for (NSArray *stream in @[ @[ @"mjpeg", [pages t:@"nset.camera_mjpeg"] ],
                               @[ @"snapshot", [pages t:@"nset.camera_snapshot"] ],
                               @[ @"h264", [pages t:@"nset.camera_rtsp"] ] ]) {
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
    remove.confirmMessage = [pages t:@"editor.delete_confirm"];
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
          remove.confirmMessage = [deep t:@"editor.delete_confirm"];
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
    NSDictionary *status = [pages statusNow];
    NSMutableArray *fields = [NSMutableArray array];
    NSArray *ids = [[devices allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *device in ids) {
      if (!DBSafeId(device)) continue;
      NSDictionary *entry = DBDict([devices objectForKey:device]);
      NSString *name = [DBConfigUtil str:entry path:@"name"] ?: device;
      NSMutableArray *parts = [NSMutableArray arrayWithObject:
          [pages roleLabel:[DBConfigUtil str:entry path:@"role"]]];
      if ([device isEqualToString:pages.nodeId]) [parts addObject:[pages t:@"editor.this_device"]];
      [parts addObject:[pages healthText:
          [DBSettingsLogic peerHealth:[pages peerFor:device status:status]]]];
      [fields addObject:[pages page:name detail:[parts componentsJoinedByString:@" · "]
                              build:^DBEditPage *{ return [weakSelf devicePage:device]; }]];
    }
    DBEditField *security = [pages page:[pages t:@"security.title"] detail:nil
                                  build:^DBEditPage *{ return [weakSelf clusterSecurityPage]; }];
    return @[ [DBEditSection title:nil fields:fields],
              [DBEditSection title:nil fields:@[ security ]] ];
  }];
}

- (DBEditPage *)devicePage:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *base = [@"devices." stringByAppendingString:device];
  return [DBEditPage title:[self deviceName:device] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *entry = DBDict([pages at:base]);
    NSDictionary *peer = [pages peerFor:device status:[pages statusNow]];
    BOOL me = [device isEqualToString:pages.nodeId];
    NSString *role = [DBConfigUtil str:entry path:@"role"] ?: @"";
    NSString *door = [DBConfigUtil str:entry path:@"door"] ?: @"";
    BOOL doorStation = [role isEqualToString:@"door_station"];
    NSString *doorLabel = [door length] > 0
        ? [pages label:[pages at:[@"doors." stringByAppendingString:door]] fallback:door] : @"";
    NSMutableArray *fields = [NSMutableArray array];
    DBEditSection *main = nil;
    if (me) {
      // This device's own identity lives in boot.json and is changed under Device, where the
      // application restarts itself; nothing here writes configuration for it.
      [fields addObject:[pages info:[pages t:@"settings.device_name"]
                              value:[DBConfigUtil str:entry path:@"name"]]];
      [fields addObject:[pages info:[pages t:@"settings.device_role"] value:[pages roleLabel:role]]];
      if (doorStation)
        [fields addObject:[pages info:[pages t:@"settings.device_door"] value:doorLabel]];
      main = [DBEditSection title:nil fields:fields];
      main.footer = [pages t:@"settings.device_self_hint"];
    } else {
      DBEditField *name = [DBEditField kind:DBEditKindText title:[pages t:@"settings.device_name"]
                                      value:[DBConfigUtil str:entry path:@"name"] ?: @""];
      name.onChange = ^BOOL(id value) {
        NSString *text = DBTrim([value description] ?: @"");
        if (![DBSettingsLogic validDeviceName:text])
          return [weakSelf refuse:[weakSelf t:@"editor.name_length"]];
        return [weakSelf setKey:[base stringByAppendingString:@".name"] value:text];
      };
      [fields addObject:name];
      BOOL editable = [DBSettingsLogic roleEditableForDevice:entry peer:peer];
      if (editable) {
        [fields addObject:[pages page:[pages t:@"settings.device_role"]
                               detail:[pages roleLabel:role]
                                build:^DBEditPage *{ return [weakSelf identityPage:device]; }]];
        if (doorStation)
          [fields addObject:[pages page:[pages t:@"settings.device_door"] detail:doorLabel
                                  build:^DBEditPage *{ return [weakSelf identityPage:device]; }]];
      } else {
        [fields addObject:[pages info:[pages t:@"settings.device_role"]
                                value:[pages roleLabel:role]]];
      }
      main = [DBEditSection title:nil fields:fields];
      main.footer = [pages t:(editable ? @"editor.role_restart_hint" : @"editor.role_fixed")];
    }
    [fields addObject:[pages info:[pages t:@"editor.device_id"] value:device]];
    main.fields = fields;

    NSDictionary *health = [DBSettingsLogic peerHealth:peer];
    NSString *fingerprint = [DBSettingsLogic fingerprintText:
        [DBConfigUtil str:peer path:@"tls_sha256"] ?: [DBConfigUtil str:entry path:@"tls_sha256"]];
    DBEditSection *state = [DBEditSection title:[pages t:@"editor.device_health"] fields:@[
      [pages info:[pages t:@"editor.device_state"]
            value:[pages stateLabel:[health objectForKey:@"state"]]],
      [pages info:[pages t:@"info.version"] value:[health objectForKey:@"version"] ?: @"—"],
      [pages info:[pages t:@"power.title"]
            value:[pages batteryText:health] ?: [pages t:@"power.unknown"]],
      [pages info:[pages t:@"security.membership"] value:[pages membershipLabel:peer]],
      [pages info:[pages t:@"security.fingerprint"]
            value:fingerprint ?: [pages t:@"security.fingerprint_unavailable"]],
    ]];
    NSMutableArray *sections = [NSMutableArray arrayWithObjects:main, state, nil];
    if (!me) {
      NSString *message = [pages->_texts t:@"admin.remove_device_confirm",
                                           [pages deviceName:device], nil];
      DBEditField *remove = [pages danger:[pages t:@"editor.remove_device"] message:message
                                    block:^{
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
      [sections addObject:[DBEditSection title:nil fields:@[ remove ]]];
    }
    return sections;
  }];
}

// Role and door of another device: indoor panel, or door station on one of the doors no
// live door station serves, or on a new door id. Nothing is written until the operator
// confirms that the target restarts.
- (DBEditPage *)identityPage:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *base = [@"devices." stringByAppendingString:device];
  return [DBEditPage title:[self t:@"settings.device_role"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *cfg = [pages cfg];
    NSString *role = [DBConfigUtil str:cfg path:[base stringByAppendingString:@".role"]] ?: @"";
    NSString *door = [DBConfigUtil str:cfg path:[base stringByAppendingString:@".door"]] ?: @"";
    BOOL doorStation = [role isEqualToString:@"door_station"];
    DBEditField *indoor = [pages action:[pages t:@"admin.role_indoor"] block:^{
      [weakSelf applyIdentity:device role:@"indoor_panel" door:@""];
    }];
    indoor.checked = [role isEqualToString:@"indoor_panel"];
    NSDictionary *doors = DBDict([pages at:@"doors"]);
    NSMutableArray *doorFields = [NSMutableArray array];
    for (NSString *candidate in [DBSettingsLogic unservedDoorsInConfig:cfg
                                                                status:[pages statusNow]
                                                             forDevice:device]) {
      DBEditField *row = [pages action:[pages label:[doors objectForKey:candidate]
                                           fallback:candidate]
                                 block:^{
        [weakSelf applyIdentity:device role:@"door_station" door:candidate];
      }];
      row.detail = candidate;
      row.checked = doorStation && [door isEqualToString:candidate];
      [doorFields addObject:row];
    }
    [doorFields addObject:[pages action:[pages t:@"editor.new_door"] block:^{
      DBSettingsPages *inner = weakSelf;
      [editor promptTitle:[inner t:@"settings.device_door"]
                    value:[DBSettingsLogic suggestedDoorIdForDevice:device]
              placeholder:[inner t:@"settings.device_door_desc"]
                 keyboard:UIKeyboardTypeASCIICapable secure:NO then:^(NSString *text) {
        DBSettingsPages *deep = weakSelf;
        NSString *entered = DBTrim(text);
        if (![DBSettingsLogic validDoorId:entered]) {
          [editor showMessage:[deep t:@"settings.device_door_desc"]];
          return;
        }
        [deep applyIdentity:device role:@"door_station" door:entered];
      }];
    }]];
    DBEditSection *doorSection = [DBEditSection title:[pages t:@"admin.role_door"]
                                               fields:doorFields];
    doorSection.footer = [pages t:@"editor.role_restart_hint"];
    return @[ [DBEditSection title:nil fields:@[ indoor ]], doorSection ];
  }];
}

- (void)applyIdentity:(NSString *)device role:(NSString *)role door:(NSString *)door {
  // This device changes its own role under Device, through boot.json and its own restart.
  if ([device isEqualToString:_nodeId]) return;
  NSArray *ops = [DBSettingsLogic roleChangeOpsForDevice:device role:role door:door];
  if (ops == nil) {
    [_editor showMessage:[self t:@"admin.door_required"]];
    return;
  }
  NSMutableString *message = [NSMutableString stringWithString:
      [_texts t:@"editor.role_restart_confirm", [self deviceName:device], nil]];
  NSString *bound = [role isEqualToString:@"door_station"]
      ? [DBSettingsLogic deviceBoundToDoor:door config:[self cfg] excluding:device] : nil;
  if (bound)
    [message appendFormat:@"\n%@", [_texts t:@"editor.door_bound_warning",
                                             [self deviceName:bound], nil]];
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *title = [role isEqualToString:@"door_station"]
      ? [NSString stringWithFormat:@"%@ · %@", [self roleLabel:role], door] : [self roleLabel:role];
  [_editor confirmTitle:title message:message then:^{
    DBSettingsPages *pages = weakSelf;
    if (pages && [pages commit:ops]) [editor popPage];
  }];
}

#pragma mark - cluster security and legacy access

- (DBEditPage *)clusterSecurityPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:[self t:@"security.title"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *node = DBDict([[pages statusNow] objectForKey:@"node"]);
    NSString *fingerprint = [DBSettingsLogic fingerprintText:[DBConfigUtil str:node
                                                                         path:@"tls_sha256"]];
    DBEditSection *identity = [DBEditSection title:nil fields:@[
      [pages info:[pages t:@"security.fingerprint"]
            value:fingerprint ?: [pages t:@"security.fingerprint_unavailable"]],
      [pages info:[pages t:@"security.membership"] value:[pages membershipLabel:node]],
    ]];
    identity.footer = [pages t:@"security.fingerprint_hint"];

    DBEditField *rebuild = [pages danger:[pages t:@"security.rebuild"]
                                 message:[pages t:@"security.rebuild_confirm"] block:^{
      DBSettingsPages *inner = weakSelf;
      // The administrator password is asked for again, whatever session is open.
      inner->_http = nil;
      [inner adminRequest:@"POST" path:@"/api/pairing/rebuild" body:@{}
                     then:^(NSInteger status, NSDictionary *json) {
        DBSettingsPages *deep = weakSelf;
        BOOL ok = status == 200 && [[json objectForKey:@"ok"] boolValue];
        [editor showMessage:ok ? [deep t:@"security.rebuild_done"]
            : [deep->_texts t:@"security.failed",
                  [DBConfigUtil evStr:json key:@"err"] ?: @"", nil]];
        [editor reloadPage];
      }];
    }];
    DBEditSection *dangerZone = [DBEditSection title:[pages t:@"admin.danger_zone"]
                                              fields:@[ rebuild ]];
    dangerZone.footer = [pages t:@"security.rebuild_hint"];

    NSArray *refs = DBArray([pages at:@"panel.token_refs"]);
    NSMutableArray *legacy = [NSMutableArray array];
    [legacy addObject:[pages info:[pages t:@"admin.panel_token"]
                            value:[refs count] > 0 ? [pages t:@"editor.secret_set"]
                                                   : [pages t:@"editor.secret_unset"]]];
    [legacy addObject:[pages danger:[pages t:@"admin.rotate"]
                            message:[pages t:@"admin.rotate_confirm"] block:^{
      [weakSelf adminRequest:@"POST" path:@"/api/panel-token/rotate" body:@{}
                        then:^(NSInteger status, NSDictionary *json) {
        DBSettingsPages *deep = weakSelf;
        NSString *token = [DBConfigUtil evStr:json key:@"token"];
        if (status != 200 || [token length] == 0) {
          [deep showFailure:json];
          return;
        }
        [editor reloadPage];
        [editor pushPage:[deep legacyTokenPage:token]];
      }];
    }]];
    if ([refs count] > 0) {
      // Stores a token another node issued under the reference the cluster already uses.
      DBEditField *provision = [DBEditField kind:DBEditKindSecret
                                           title:[pages t:@"admin.provision_this_node"]
                                           value:@NO];
      provision.detail = @"";
      provision.onChange = ^BOOL(id value) {
        NSString *token = [value description];
        NSString *ref = [[refs objectAtIndex:0] description];
        if ([token length] == 0) return NO;
        [weakSelf adminRequest:@"POST" path:@"/api/panel-token/provision"
                          body:@{ @"secret_ref" : ref, @"token" : token }
                          then:^(NSInteger status, NSDictionary *json) {
          DBSettingsPages *deep = weakSelf;
          if (status == 200 && [[json objectForKey:@"ok"] boolValue]) [deep toast:@"settings.saved"];
          else [deep showFailure:json];
        }];
        return NO;
      };
      [legacy addObject:provision];
    }
    DBEditSection *legacySection = [DBEditSection title:[pages t:@"editor.legacy_panel"]
                                                 fields:legacy];
    legacySection.footer = [pages t:@"editor.legacy_panel_hint"];
    return @[ identity, dangerZone, legacySection ];
  }];
}

// Shown once: the token is not kept anywhere this screen can read it back from.
- (DBEditPage *)legacyTokenPage:(NSString *)token {
  __weak DBSettingsPages *weakSelf = self;
  NSString *host = [DBConfigUtil urlHost:[self adminHost]];
  return [DBEditPage title:[self t:@"admin.panel_token"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray arrayWithObject:
        [pages info:[pages t:@"admin.panel_token"] value:token]];
    for (NSString *screen in @[ @"door", @"monitor" ]) {
      NSString *link = [NSString stringWithFormat:@"https://%@:47443/panel/%@#k=%@", host, screen,
                                                  token];
      DBEditField *field = [pages info:[pages t:[@"panels.link_" stringByAppendingString:screen]]
                                 value:link];
      field.image = [DBQrCode imageForString:link targetPx:240];
      [fields addObject:field];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.panel_link_once"];
    return @[ section ];
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
      reset.confirmMessage = [pages t:@"editor.wording_reset_confirm"];
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
  field.onChange = ^BOOL(id value) {
    return [weakSelf setKey:key value:[[value description] uppercaseString]];
  };
  return field;
}

// A colour that is automatic until set: the colour row, plus the row that clears it.
- (NSArray *)optionalColor:(NSString *)title key:(NSString *)key {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSMutableArray *fields = [NSMutableArray arrayWithObject:
      [self colorField:title key:key fallback:nil]];
  if ([DBConfigUtil str:[self cfg] path:key])
    [fields addObject:[self action:[NSString stringWithFormat:@"%@: %@", title,
                                       [self t:@"editor.automatic"]]
                             block:^{
      if ([weakSelf deleteKey:key]) [editor reloadPage];
    }]];
  return fields;
}

// The theme of the whole cluster (device nil) or the override of one device.
- (DBEditPage *)themeScopePage:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *prefix = device ? [NSString stringWithFormat:@"devices.%@.local.theme", device]
                            : @"display.theme";
  NSString *title = device == nil ? [self t:@"editor.all_devices"]
      : ([device isEqualToString:_nodeId] ? [self t:@"editor.this_device"]
                                          : [self deviceName:device]);
  return [DBEditPage title:title build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *cfg = [pages cfg];
    // A device shows the cluster value wherever it has no override of its own.
    NSString *(^inherited)(NSString *, NSString *) = ^NSString *(NSString *leaf, NSString *def) {
      return device ? ([DBConfigUtil str:cfg path:[@"display.theme." stringByAppendingString:leaf]]
                           ?: def) : def;
    };
    NSString *colorKey = [prefix stringByAppendingString:@".bg_color"];
    NSString *imageKey = [prefix stringByAppendingString:@".bg_image"];
    DBEditField *color = [pages colorField:[pages t:@"settings.theme_bg"] key:colorKey
                                  fallback:inherited(@"bg_color", nil)];

    id storedImage = [pages at:imageKey];
    NSString *image = [storedImage isKindOfClass:[NSString class]] ? storedImage : @"";
    NSMutableArray *imageChoices = [NSMutableArray array];
    if (device) [imageChoices addObject:@[ @"inherit", [pages t:@"editor.inherited"] ]];
    [imageChoices addObject:@[ @"none", [pages t:@"admin.theme_no_image"] ]];
    NSDictionary *assets = DBDict([pages at:@"assets"]);
    for (NSString *hash in [[assets allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      if (![[DBConfigUtil str:DBDict([assets objectForKey:hash]) path:@"type"] hasPrefix:@"image/"])
        continue;
      [imageChoices addObject:@[ hash, [pages assetLabel:hash] ]];
    }
    NSString *currentImage = [image length] > 0 ? image
        : ((device && storedImage == nil) ? @"inherit" : @"none");
    DBEditField *pick = [DBEditField kind:DBEditKindChoice
                                    title:[pages t:@"admin.theme_bg_image"] value:currentImage];
    pick.choices = imageChoices;
    pick.onChange = ^BOOL(id value) {
      // A device stores null for "no image here"; removing the key inherits again.
      if ([value isEqual:@"inherit"]) return [weakSelf deleteKey:imageKey];
      if ([value isEqual:@"none"])
        return device ? [weakSelf setKey:imageKey value:[NSNull null]]
                      : [weakSelf deleteKey:imageKey];
      return [weakSelf setKey:imageKey value:value];
    };
    DBEditField *choose = [pages action:[pages t:@"editor.choose_photo"] block:^{
      [weakSelf pickImageForKey:imageKey];
    }];
    DBEditSection *imageSection = [DBEditSection title:[pages t:@"editor.background_image"]
                                                fields:@[ pick, choose ]];
    imageSection.footer = [pages t:@"admin.theme_image_hint"];

    NSString *b = [prefix stringByAppendingString:@".backdrop."];
    DBEditField *backdropOn = [pages toggle:[pages t:@"theme.backdrop_enabled"]
        key:[b stringByAppendingString:@"enabled"]
        def:(device ? [DBConfigUtil boolVal:cfg path:@"display.theme.backdrop.enabled" def:YES]
                    : YES)];
    DBEditField *backdropColor = [pages colorField:[pages t:@"prefs.backdrop_color"]
                                               key:[b stringByAppendingString:@"color"]
                                          fallback:inherited(@"backdrop.color", @"#000000")];
    DBEditField *opacity = [pages number:[pages t:@"prefs.backdrop_opacity"]
        key:[b stringByAppendingString:@"opacity"]
        def:(device ? [DBConfigUtil intVal:cfg path:@"display.theme.backdrop.opacity" def:62] : 62)
        min:0 max:100];
    DBEditSection *backdrop = [DBEditSection title:[pages t:@"theme.backdrop"]
                                            fields:@[ backdropOn, backdropColor, opacity ]];
    backdrop.footer = [pages t:@"theme.backdrop_hint"];

    DBEditField *blur = [pages number:[pages t:@"theme.glass_blur_radius"]
        key:[prefix stringByAppendingString:@".glass.blur_radius"]
        def:(device ? [DBConfigUtil intVal:cfg path:@"display.theme.glass.blur_radius" def:32] : 32)
        min:0 max:40];
    DBEditSection *glass = [DBEditSection title:nil fields:@[ blur ]];
    glass.footer = [pages t:@"theme.glass_blur_hint"];

    DBEditSection *callButton = [DBEditSection title:nil
        fields:[pages optionalColor:[pages t:@"theme.call_button"]
                                key:[prefix stringByAppendingString:@".call_button_bg"]]];

    NSMutableArray *inks = [NSMutableArray array];
    for (NSString *region in @[ @"clock", @"date", @"status_line", @"hint", @"tile_label",
                                @"footer", @"notice" ]) {
      NSString *key = [NSString stringWithFormat:@"%@.ink_override.%@", prefix, region];
      NSString *regionTitle = [pages t:[@"theme.region_" stringByAppendingString:region]];
      [inks addObject:[pages page:regionTitle
                           detail:[DBConfigUtil str:cfg path:key] ?: [pages t:@"editor.automatic"]
                            build:^DBEditPage *{
        return [DBEditPage title:regionTitle build:^NSArray *{
          DBSettingsPages *deep = weakSelf;
          DBEditSection *section = [DBEditSection title:nil
              fields:[deep optionalColor:[deep t:@"editor.ink"] key:key]];
          section.footer = [deep t:@"editor.ink_hint"];
          return @[ section ];
        }];
      }]];
    }
    NSMutableArray *sections = [NSMutableArray arrayWithObjects:
        [DBEditSection title:nil fields:@[ color ]], imageSection, backdrop, glass, callButton,
        [DBEditSection title:[pages t:@"editor.ink_overrides"] fields:inks], nil];
    if (device && [DBDict([pages at:prefix]) count] > 0) {
      DBEditField *reset = [pages danger:[pages t:@"editor.use_cluster_theme"]
                                 message:[pages t:@"editor.theme_reset_confirm"] block:^{
        if ([weakSelf deleteKey:prefix]) [editor reloadPage];
      }];
      [sections addObject:[DBEditSection title:nil fields:@[ reset ]]];
    }
    return sections;
  }];
}

// Scope first, as in the web admin: the cluster theme, or the override of any one device.
- (DBEditPage *)themePage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"settings.theme_bg"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *cfg = [pages cfg];
    DBEditField *cluster = [pages page:[pages t:@"editor.all_devices"]
                                detail:[DBConfigUtil str:cfg path:@"display.theme.bg_color"] ?: @""
                                 build:^DBEditPage *{ return [weakSelf themeScopePage:nil]; }];
    NSMutableArray *devices = [NSMutableArray array];
    for (NSArray *choice in [pages deviceChoicesWithRole:nil]) {
      NSString *device = [choice objectAtIndex:0];
      BOOL me = [device isEqualToString:pages.nodeId];
      BOOL overridden = [DBDict([pages at:[NSString stringWithFormat:@"devices.%@.local.theme",
                                              device]]) count] > 0;
      DBEditField *row = [pages page:(me ? [pages t:@"editor.this_device"]
                                         : [choice objectAtIndex:1])
                              detail:[pages t:(overridden ? @"admin.theme_override_here"
                                                          : @"editor.inherited")]
                               build:^DBEditPage *{ return [weakSelf themeScopePage:device]; }];
      if (me) [devices insertObject:row atIndex:0];
      else [devices addObject:row];
    }
    DBEditSection *scope = [DBEditSection title:nil fields:@[ cluster ]];
    scope.footer = [pages t:@"admin.theme_global_hint"];
    DBEditSection *overrides = [DBEditSection title:[pages t:@"admin.devices"] fields:devices];
    overrides.footer = [pages t:@"admin.theme_device_hint"];
    DBEditField *images = [pages page:[pages t:@"editor.images"] detail:nil
                                build:^DBEditPage *{ return [weakSelf assetsPage:@"image/"]; }];
    return @[ scope, overrides, [DBEditSection title:nil fields:@[ images ]] ];
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
  // An empty scope uploads the photo without assigning it to a setting.
  _pickerScope = [key copy] ?: @"";
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
  if (image == nil || key == nil) return;
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
    NSMutableArray *events = [NSMutableArray array];
    for (NSArray *sound in @[ @[ @"admin.launch_sound", @"ui.launch_sound", @"title_display" ],
                              @[ @"admin.door_call_sound", @"ui.call_sound", @"outdoor_call_alert" ],
                              @[ @"prefs.button_sound", @"ui.button_sound", @"button_click" ],
                              @[ @"admin.update_sound", @"ui.update_sound", @"indoor_update" ] ]) {
      NSString *soundKey = [sound objectAtIndex:1];
      // An empty string is "do not play", so it must not fall back to the default.
      DBEditField *field = [DBEditField kind:DBEditKindChoice
                                       title:[pages t:[sound objectAtIndex:0]]
                                       value:[pages rawString:soundKey def:[sound objectAtIndex:2]]];
      field.choices = [pages eventSoundChoices];
      field.onChange = ^BOOL(id value) { return [weakSelf setKey:soundKey value:value]; };
      [events addObject:field];
    }
    DBEditSection *eventSounds = [DBEditSection title:[pages t:@"admin.sound_manager"]
                                               fields:events];
    eventSounds.footer = [pages t:@"admin.sound_manager_hint"];
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
    return @[ [DBEditSection title:nil fields:@[ ringtone, alarm ]], eventSounds, add,
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
    section.footer = [NSString stringWithFormat:@"%@\n%@", [pages t:@"editor.config_transfer_hint"],
                                                 [pages t:@"editor.config_transfer_clipboard"]];
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

#pragma mark - Web Push

- (DBEditPage *)webPushPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *w = @"integrations.web_push.";
  return [DBEditPage title:[self t:@"settings.web_push"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    // The sender fields are stored as strings even when empty, as the web admin writes them.
    DBEditField *(^plain)(NSString *, NSString *, UIKeyboardType) =
        ^DBEditField *(NSString *title, NSString *leaf, UIKeyboardType keyboard) {
      NSString *key = [w stringByAppendingString:leaf];
      DBEditField *field = [DBEditField kind:DBEditKindText title:title
                                       value:[pages rawString:key def:@""]];
      field.keyboard = keyboard;
      field.onChange = ^BOOL(id value) {
        return [weakSelf setKey:key value:DBTrim([value description] ?: @"")];
      };
      return field;
    };
    DBEditField *url = plain([pages t:@"admin.web_push_sender_url"], @"sender_url",
                             UIKeyboardTypeURL);
    url.placeholder = @"https://";
    DBEditField *subject = plain([pages t:@"admin.web_push_subject"], @"vapid_subject",
                                 UIKeyboardTypeEmailAddress);
    subject.placeholder = @"mailto:";
    DBEditField *publicKey = plain([pages t:@"admin.web_push_public_key"], @"vapid_public_key",
                                   UIKeyboardTypeASCIICapable);
    DBEditField *privateKey = [pages secret:[pages t:@"admin.web_push_private_key"]
                                        key:[w stringByAppendingString:@"vapid_private_key_ref"]
                                       base:@"webpush.vapid_private"];
    DBEditSection *sender = [DBEditSection title:[pages t:@"admin.web_push_backend"]
                                          fields:@[ url, subject, publicKey, privateKey ]];
    sender.footer = [pages t:@"editor.secret_hint"];

    NSString *bearerKey = [w stringByAppendingString:@"sender_secret_ref"];
    BOOL bearerSet = [pages hasSecretAt:bearerKey];
    DBEditField *useBearer = [DBEditField kind:DBEditKindBool
                                         title:[pages t:@"admin.web_push_use_sender_bearer"]
                                         value:[NSNumber numberWithBool:bearerSet]];
    void (^enterBearer)(void) = ^{
      DBSettingsPages *inner = weakSelf;
      [editor promptTitle:[inner t:@"admin.web_push_sender_bearer"] value:@"" placeholder:nil
                 keyboard:UIKeyboardTypeASCIICapable secure:YES then:^(NSString *text) {
        DBSettingsPages *deep = weakSelf;
        if ([text length] == 0) {
          [deep refuse:[deep t:@"admin.web_push_bearer_required"]];
          return;
        }
        if ([deep storeSecret:text base:@"webpush.sender" key:bearerKey]) [editor reloadPage];
      }];
    };
    useBearer.onChange = ^BOOL(id value) {
      // Off writes an empty reference, which is how Core reads "no sender authentication".
      if (![value boolValue]) return [weakSelf setKey:bearerKey value:@""];
      enterBearer();
      return [weakSelf refuse:nil];
    };
    NSMutableArray *bearer = [NSMutableArray arrayWithObject:useBearer];
    if (bearerSet) {
      DBEditField *replace = [pages action:[pages t:@"admin.web_push_sender_bearer"]
                                     block:enterBearer];
      replace.detail = [pages t:@"editor.secret_set"];
      [bearer addObject:replace];
    }

    NSDictionary *push = DBDict([[pages statusNow] objectForKey:@"web_push"]);
    NSString *(^ready)(NSString *) = ^NSString *(NSString *field) {
      return [pages t:([[push objectForKey:field] boolValue] ? @"admin.ready" : @"admin.not_ready")];
    };
    NSMutableArray *state = [NSMutableArray arrayWithObjects:
        [pages info:[pages t:@"admin.web_push_status"]
              value:[pages t:([[push objectForKey:@"configured"] boolValue] ? @"admin.enabled"
                                                                         : @"admin.disabled")]],
        [pages info:[pages t:@"admin.web_push_local_secret"] value:ready(@"local_secret_ready")],
        [pages info:[pages t:@"admin.web_push_delivery_backend"] value:ready(@"delivery_backend")],
        [pages info:[pages t:@"admin.leader"]
              value:[[DBConfigUtil str:push path:@"leader"] length] > 0
                        ? [pages deviceName:[DBConfigUtil str:push path:@"leader"]] : @"—"],
        [pages info:[pages t:@"editor.web_push_subscriptions"]
              value:[NSString stringWithFormat:@"%ld",
                        (long)[DBConfigUtil intVal:push path:@"subscriptions" def:0]]], nil];
    NSString *warning = [DBConfigUtil str:push path:@"warning_code"];
    if ([warning length] > 0)
      [state addObject:[pages info:[pages t:@"editor.web_push_warning"] value:warning]];
    return @[ sender, [DBEditSection title:nil fields:bearer],
              [DBEditSection title:[pages t:@"admin.web_push_status"] fields:state] ];
  }];
}

#pragma mark - assets

- (NSString *)assetSizeText:(NSDictionary *)asset {
  long long size = [DBConfigUtil longLongVal:asset path:@"size" def:0];
  return size >= 1024 * 1024 ? [NSString stringWithFormat:@"%.1f MB", size / 1048576.0]
                             : [NSString stringWithFormat:@"%lld KB", (size + 1023) / 1024];
}

// What deleting an asset costs: the places that fall back to their default.
- (NSString *)assetDeleteMessage:(NSString *)hash {
  NSArray *users = [[DBSettingsLogic assetReferencesInConfig:[self cfg]] objectForKey:hash];
  if ([users count] == 0) return [self t:@"editor.asset_delete_confirm"];
  return [_texts t:@"settings.asset_delete_in_use", [self assetLabel:hash],
                   [users componentsJoinedByString:@", "], nil];
}

// YES when the ledger entry is gone. A closed admin window asks for the password once and
// runs after when the retried removal succeeds.
- (BOOL)removeAssetHash:(NSString *)hash after:(void (^)(void))after {
  NSDictionary *result = [_core removeAsset:hash];
  if ([[result objectForKey:@"ok"] boolValue]) {
    [_thumbnails removeObjectForKey:hash];
    if ([_playingHash isEqualToString:hash]) [self stopPlayback];
    [self toast:@"settings.saved"];
    return YES;
  }
  NSString *err = [DBConfigUtil evStr:result key:@"err"] ?: @"";
  if ([err isEqualToString:@"admin_required"]) {
    __weak DBSettingsPages *weakSelf = self;
    [_router requestPinThen:^{
      DBSettingsPages *pages = weakSelf;
      if (pages && [pages removeAssetHash:hash after:nil] && after) after();
    }];
    return NO;
  }
  [_editor showMessage:[NSString stringWithFormat:@"%@\n%@", [self t:@"settings.save_failed"], err]];
  return NO;
}

// The asset ledger: every asset, or those of one MIME prefix. Rows open the asset's own page
// with its references, a preview, and delete.
- (DBEditPage *)assetsPage:(NSString *)typePrefix {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *title = typePrefix == nil ? [self t:@"admin.assets"]
      : ([typePrefix hasPrefix:@"image"] ? [self t:@"editor.images"] : [self t:@"editor.sounds"]);
  return [DBEditPage title:title build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *assets = DBDict([pages at:@"assets"]);
    NSDictionary *refs = [DBSettingsLogic assetReferencesInConfig:[pages cfg]];
    NSMutableArray *hashes = [NSMutableArray array];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *hash in [[assets allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      NSDictionary *asset = DBDict([assets objectForKey:hash]);
      NSString *type = [DBConfigUtil str:asset path:@"type"] ?: @"";
      if (!DBSafeId(hash) || (typePrefix && ![type hasPrefix:typePrefix])) continue;
      [hashes addObject:hash];
      NSUInteger users = [[refs objectForKey:hash] count];
      NSString *used = users > 0
          ? [pages->_texts t:@"settings.asset_used",
                [NSString stringWithFormat:@"%lu", (unsigned long)users], nil]
          : [pages t:@"admin.asset_unused"];
      [fields addObject:[pages page:[pages assetLabel:hash]
                             detail:[NSString stringWithFormat:@"%@ · %@ · %@", type,
                                        [pages assetSizeText:asset], used]
                              build:^DBEditPage *{ return [weakSelf assetPage:hash]; }]];
    }
    if ([fields count] == 0)
      [fields addObject:[pages info:[pages t:@"admin.assets_empty"] value:nil]];
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.assets_hint"];
    if ([hashes count] > 0) {
      section.deleteMessage = ^NSString *(NSInteger index) {
        return index >= 0 && index < (NSInteger)[hashes count]
            ? [weakSelf assetDeleteMessage:[hashes objectAtIndex:(NSUInteger)index]] : nil;
      };
      section.onDelete = ^BOOL(NSInteger index) {
        if (index < 0 || index >= (NSInteger)[hashes count]) return NO;
        return [weakSelf removeAssetHash:[hashes objectAtIndex:(NSUInteger)index]
                                   after:^{ [editor reloadPage]; }];
      };
    }
    if (typePrefix != nil) return @[ section ];

    BOOL recording = pages->_recorder.recording;
    DBEditField *photo = [pages action:[pages t:@"editor.choose_photo"] block:^{
      [weakSelf pickImageForKey:nil];
    }];
    DBEditField *record = [pages action:[pages t:(recording ? @"editor.stop_recording"
                                                            : @"editor.record_sound")]
                                  block:^{
      DBSettingsPages *inner = weakSelf;
      if (inner->_recorder.recording) [inner stopRecording];
      else [inner startRecording];
    }];
    DBEditSection *upload = [DBEditSection title:[pages t:@"admin.assets_upload"]
                                          fields:@[ photo, record ]];
    upload.footer = [pages t:@"editor.assets_upload_hint"];
    NSDictionary *cache = DBDict([[pages statusNow] objectForKey:@"assets"]);
    NSMutableArray *sections = [NSMutableArray arrayWithObjects:section, upload, nil];
    if ([cache objectForKey:@"total"])
      [sections addObject:[DBEditSection title:nil fields:@[
          [pages info:[pages t:@"editor.assets_cached_here"]
                value:[NSString stringWithFormat:@"%ld / %ld",
                          (long)[DBConfigUtil intVal:cache path:@"cached" def:0],
                          (long)[DBConfigUtil intVal:cache path:@"total" def:0]]] ]]];
    return sections;
  }];
}

- (DBEditPage *)assetPage:(NSString *)hash {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[self assetLabel:hash] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *asset = DBDict([pages at:[@"assets." stringByAppendingString:hash]]);
    NSString *type = [DBConfigUtil str:asset path:@"type"] ?: @"";
    DBEditSection *facts = [DBEditSection title:nil fields:@[
      [pages info:[pages t:@"admin.asset_label"] value:[pages assetLabel:hash]],
      [pages info:[pages t:@"admin.asset_type"] value:type],
      [pages info:[pages t:@"admin.asset_size"] value:[pages assetSizeText:asset]],
      [pages info:[pages t:@"editor.asset_hash"]
            value:[hash substringToIndex:MIN((NSUInteger)16, [hash length])]],
    ]];
    NSMutableArray *preview = [NSMutableArray array];
    if ([type hasPrefix:@"image/"]) {
      UIImage *thumbnail = [pages->_thumbnails objectForKey:hash];
      DBEditField *picture = [pages info:[pages t:(thumbnail ? @"admin.theme_preview"
                                                             : @"editor.loading")] value:nil];
      picture.image = thumbnail;
      [preview addObject:picture];
    } else if ([type hasPrefix:@"audio/"]) {
      BOOL playing = [pages->_playingHash isEqualToString:hash];
      [preview addObject:[pages action:[pages t:(playing ? @"editor.stop_playing"
                                                         : @"admin.audio_play")]
                                 block:^{ [weakSelf togglePlayback:hash]; }]];
    }
    NSMutableArray *users = [NSMutableArray array];
    for (NSString *where in [[DBSettingsLogic assetReferencesInConfig:[pages cfg]]
             objectForKey:hash])
      [users addObject:[pages info:where value:nil]];
    if ([users count] == 0)
      [users addObject:[pages info:[pages t:@"admin.asset_unused"] value:nil]];
    DBEditField *remove = [pages danger:[pages t:@"editor.delete"]
                                message:[pages assetDeleteMessage:hash] block:^{
      if ([weakSelf removeAssetHash:hash after:^{ [editor popPage]; }]) [editor popPage];
    }];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:facts];
    if ([preview count] > 0) [sections addObject:[DBEditSection title:nil fields:preview]];
    [sections addObject:[DBEditSection title:[pages t:@"admin.asset_used_by"] fields:users]];
    [sections addObject:[DBEditSection title:nil fields:@[ remove ]]];
    return sections;
  }];
  page.onAppear = ^{ [weakSelf loadThumbnail:hash]; };
  return page;
}

// Reads one asset from this device's own Core asset cache, off the main thread. The asset
// route is public on loopback; no administrator session is involved.
- (void)fetchAsset:(NSString *)hash then:(void (^)(NSData *data))then {
  if (!DBSafeId(hash)) {
    then(nil);
    return;
  }
  NSInteger port = _boot.httpPort > 0 ? _boot.httpPort : 47180;
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/asset/%@",
                                                               (long)port, hash]];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSURLRequest *request = [NSURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response
                                                     error:NULL];
    if (![response isKindOfClass:[NSHTTPURLResponse class]] || response.statusCode != 200)
      data = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ then(data); });
  });
}

// Decodes and scales on a background queue: an A4 must not decode a wallpaper-sized JPEG
// on the main thread.
- (void)loadThumbnail:(NSString *)hash {
  NSString *type = [DBConfigUtil str:[self cfg]
                                path:[NSString stringWithFormat:@"assets.%@.type", hash]];
  if (![type hasPrefix:@"image/"] || [_thumbnails objectForKey:hash]) return;
  __weak DBSettingsPages *weakSelf = self;
  [self fetchAsset:hash then:^(NSData *data) {
    if ([data length] == 0) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      UIImage *image = [UIImage imageWithData:data];
      CGSize size = image.size;
      if (image == nil || size.width < 1 || size.height < 1) return;
      CGFloat scale = MIN(1.0f, 160.0f / MAX(size.width, size.height));
      CGSize target = CGSizeMake(MAX(1, floorf(size.width * scale)),
                                 MAX(1, floorf(size.height * scale)));
      UIGraphicsBeginImageContextWithOptions(target, YES, 1);
      [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
      UIImage *thumbnail = UIGraphicsGetImageFromCurrentImageContext();
      UIGraphicsEndImageContext();
      dispatch_async(dispatch_get_main_queue(), ^{
        DBSettingsPages *pages = weakSelf;
        if (!pages || thumbnail == nil) return;
        if (pages->_thumbnails == nil) pages->_thumbnails = [[NSMutableDictionary alloc] init];
        [pages->_thumbnails setObject:thumbnail forKey:hash];
        [pages->_editor reloadPage];
      });
    });
  }];
}

- (void)stopPlayback {
  _player.delegate = nil;
  [_player stop];
  _player = nil;
  _playingHash = nil;
}

- (void)togglePlayback:(NSString *)hash {
  BOOL same = [_playingHash isEqualToString:hash];
  [self stopPlayback];
  if (same) {
    [_editor reloadPage];
    return;
  }
  __weak DBSettingsPages *weakSelf = self;
  [self fetchAsset:hash then:^(NSData *data) {
    DBSettingsPages *pages = weakSelf;
    if (!pages) return;
    AVAudioPlayer *player = [data length] > 0 ? [[AVAudioPlayer alloc] initWithData:data error:NULL]
                                              : nil;
    player.delegate = pages;
    if (player == nil || ![player play]) {
      [pages toast:@"speech.unavailable"];
      return;
    }
    pages->_player = player;
    pages->_playingHash = [hash copy];
    [pages->_editor reloadPage];
  }];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
  (void)flag;
  if (player != _player) return;
  [self stopPlayback];
  [_editor reloadPage];
}

#pragma mark - speech

- (DBEditPage *)speechPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  __block NSArray *items = nil;
  return [DBEditPage title:[self t:@"speech.settings"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSString *keyRef = @"speech.google_key_ref";
    DBEditField *provider = [pages choice:[pages t:@"speech.provider"] key:@"speech.provider"
                                      def:@"system"
                                  choices:@[ @[ @"system", [pages t:@"speech.system"] ],
                                             @[ @"google", @"Google Cloud Text-to-Speech" ] ]];
    provider.onChange = ^BOOL(id value) {
      DBSettingsPages *inner = weakSelf;
      if ([value isEqual:@"google"] && ![inner hasSecretAt:keyRef])
        return [inner refuse:[inner t:@"speech.key_required"]];
      return [inner setKey:@"speech.provider" value:value];
    };
    // The key is stored on this device, which becomes the node that generates the audio.
    DBEditField *apiKey = [DBEditField kind:DBEditKindSecret title:[pages t:@"speech.api_key"]
                                      value:[NSNumber numberWithBool:[pages hasSecretAt:keyRef]]];
    apiKey.onChange = ^BOOL(id value) {
      DBSettingsPages *inner = weakSelf;
      NSString *secret = [value description] ?: @"";
      NSString *suffix = DBRandomHex(4);
      if ([secret length] == 0 || [suffix length] == 0 || [inner.nodeId length] == 0) return NO;
      NSString *name = [@"speech.google.key." stringByAppendingString:suffix];
      if (![inner->_core storeSecret:name value:secret]) {
        [inner toast:@"editor.secret_store_failed"];
        return NO;
      }
      return [inner commit:@[ [inner set:keyRef value:[@"secret:" stringByAppendingString:name]],
                              [inner set:@"speech.generator_node" value:inner.nodeId] ]];
    };
    NSString *generator = [DBConfigUtil str:[pages cfg] path:@"speech.generator_node"];
    DBEditSection *service = [DBEditSection title:nil fields:@[
      provider, apiKey,
      [pages info:[pages t:@"speech.generator"]
            value:[generator length] > 0 ? [pages deviceName:generator] : @"—"] ]];
    service.footer = [pages t:@"speech.cloud_hint"];

    NSDictionary *defaults = @{ @"ja" : @"ja-JP-Standard-A", @"en" : @"en-US-Standard-A",
                                @"zh" : @"cmn-CN-Standard-A" };
    NSMutableArray *voices = [NSMutableArray array];
    for (NSString *lang in kDBLangs()) {
      NSString *current = [DBConfigUtil str:[pages cfg]
                                       path:[@"speech.voices." stringByAppendingString:lang]]
          ?: [defaults objectForKey:lang];
      DBEditField *voice = [DBEditField kind:DBEditKindText
                                       title:[DBTexts langDisplayName:lang] value:current];
      voice.keyboard = UIKeyboardTypeASCIICapable;
      voice.placeholder = [defaults objectForKey:lang];
      voice.onChange = ^BOOL(id value) {
        DBSettingsPages *inner = weakSelf;
        // The three voices are one object in configuration.
        NSMutableDictionary *next = [defaults mutableCopy];
        [next addEntriesFromDictionary:DBDict([inner at:@"speech.voices"])];
        NSString *text = DBTrim([value description] ?: @"");
        [next setObject:([text length] > 0 ? text : [defaults objectForKey:lang]) forKey:lang];
        return [inner setKey:@"speech.voices" value:next];
      };
      [voices addObject:voice];
    }
    DBEditField *rate = [DBEditField kind:DBEditKindText title:[pages t:@"speech.rate"]
        value:[NSString stringWithFormat:@"%g",
                  [DBConfigUtil doubleVal:[pages cfg] path:@"speech.speaking_rate" def:1.0]]];
    rate.keyboard = UIKeyboardTypeNumbersAndPunctuation;
    rate.onChange = ^BOOL(id value) {
      double parsed = 0;
      if (![DBSettingsLogic parseSpeakingRate:[value description] into:&parsed])
        return [weakSelf refuse:[weakSelf t:@"speech.rate_invalid"]];
      return [weakSelf setKey:@"speech.speaking_rate" value:[NSNumber numberWithDouble:parsed]];
    };
    DBEditField *autoCache = [pages toggle:[pages t:@"speech.auto_cache"] key:@"speech.auto_cache"
                                       def:YES];
    DBEditSection *voice = [DBEditSection title:[pages t:@"speech.voice"] fields:voices];
    DBEditSection *tuning = [DBEditSection title:nil fields:@[ rate, autoCache ]];

    void (^refresh)(void) = ^{
      [weakSelf adminRequest:@"GET" path:@"/api/tts" body:nil
                        then:^(NSInteger status, NSDictionary *json) {
        if (status != 200) {
          [weakSelf showFailure:json];
          return;
        }
        items = DBArray([json objectForKey:@"items"]);
        [editor reloadPage];
      }];
    };
    NSMutableArray *cache = [NSMutableArray array];
    NSDictionary *replies = DBDict([pages at:@"quick_replies"]);
    for (id candidate in items) {
      NSDictionary *item = DBDict(candidate);
      NSString *reply = [DBConfigUtil evStr:item key:@"reply_id"] ?: @"";
      NSString *state = [DBConfigUtil evStr:item key:@"state"] ?: @"pending";
      NSString *label = [pages t:[@"speech.state_" stringByAppendingString:state]];
      NSString *error = [DBConfigUtil evStr:item key:@"error"];
      [cache addObject:[pages info:[NSString stringWithFormat:@"%@ (%@)",
                                       [pages label:[replies objectForKey:reply] fallback:reply],
                                       [DBConfigUtil evStr:item key:@"lang"] ?: @""]
                             value:[error length] > 0
                                       ? [NSString stringWithFormat:@"%@ · %@", label, error]
                                       : label]];
    }
    [cache addObject:[pages action:[pages t:@"speech.refresh"] block:refresh]];
    [cache addObject:[pages action:[pages t:@"speech.retry"] block:^{
      [weakSelf adminRequest:@"POST" path:@"/api/tts/cache" body:@{}
                        then:^(NSInteger status, NSDictionary *json) {
        if (status == 200 && [[json objectForKey:@"ok"] boolValue]) refresh();
        else [weakSelf showFailure:json];
      }];
    }]];
    return @[ service, voice, tuning,
              [DBEditSection title:[pages t:@"speech.status"] fields:cache] ];
  }];
}

#pragma mark - video playback policy

- (NSString *)strategyLabel:(NSString *)identifier {
  if ([identifier isEqualToString:@"h264_low_latency"]) return [self t:@"admin.video_low_latency"];
  if ([identifier isEqualToString:@"h264_hls"]) return [self t:@"admin.video_hls"];
  if ([identifier isEqualToString:@"mjpeg"]) return [self t:@"settings.playback_mjpeg"];
  return identifier;
}

// The strategies an editor at key shows: the stored profile, or for a pair without an
// override the global profile it inherits.
- (NSArray *)strategiesAt:(NSString *)key {
  NSDictionary *stored = DBDict([self at:key]);
  if ([stored count] == 0 && ![key isEqualToString:@"video_playback.global"])
    stored = DBDict([self at:@"video_playback.global"]);
  return [DBSettingsLogic normalizedPlaybackStrategies:stored];
}

- (BOOL)writeStrategies:(NSArray *)strategies at:(NSString *)key {
  NSString *error = [DBSettingsLogic playbackErrorForStrategies:strategies];
  if (error)
    return [self refuse:[self t:([error isEqualToString:@"one_required"]
                                     ? @"admin.playback_one_required"
                                     : @"admin.playback_timeout_range")]];
  return [self setKey:key value:[DBSettingsLogic playbackProfile:DBDict([self at:key])
                                                  withStrategies:strategies]];
}

- (BOOL)updateStrategy:(NSString *)identifier at:(NSString *)key field:(NSString *)field
                 value:(id)value {
  NSMutableArray *next = [NSMutableArray array];
  for (NSDictionary *strategy in [self strategiesAt:key]) {
    NSMutableDictionary *copy = [strategy mutableCopy];
    if ([[strategy objectForKey:@"id"] isEqual:identifier]) [copy setObject:value forKey:field];
    [next addObject:copy];
  }
  return [self writeStrategies:next at:key];
}

// One profile: the ordered strategies, each with its switch and two timeouts. pair names
// the override this profile is, so it can be deleted back to the global profile.
- (DBEditPage *)playbackProfilePage:(NSString *)key title:(NSString *)title pair:(BOOL)pair {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:title build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    for (NSDictionary *strategy in [pages strategiesAt:key]) {
      NSString *identifier = [strategy objectForKey:@"id"];
      NSString *detail = [NSString stringWithFormat:@"%@ · %@ / %@ ms",
          [pages t:([[strategy objectForKey:@"enabled"] boolValue] ? @"editor.on" : @"editor.off")],
          [strategy objectForKey:@"startup_timeout_ms"], [strategy objectForKey:@"stall_timeout_ms"]];
      [fields addObject:[pages page:[pages strategyLabel:identifier] detail:detail
                              build:^DBEditPage *{
        return [weakSelf strategyPage:identifier at:key];
      }]];
    }
    DBEditSection *list = [DBEditSection title:[pages t:@"admin.playback_strategy"] fields:fields];
    list.footer = [pages t:@"settings.video_policy_native"];
    list.onMove = ^BOOL(NSInteger from, NSInteger to) {
      NSMutableArray *next = [NSMutableArray arrayWithArray:[weakSelf strategiesAt:key]];
      if (from < 0 || to < 0 || from >= (NSInteger)[next count] || to >= (NSInteger)[next count])
        return NO;
      id moved = [next objectAtIndex:(NSUInteger)from];
      [next removeObjectAtIndex:(NSUInteger)from];
      [next insertObject:moved atIndex:(NSUInteger)to];
      return [weakSelf writeStrategies:next at:key];
    };
    NSMutableArray *sections = [NSMutableArray arrayWithObject:list];
    if (pair) {
      BOOL overridden = [DBDict([pages at:key]) count] > 0;
      NSMutableArray *state = [NSMutableArray arrayWithObject:
          [pages info:[pages t:(overridden ? @"admin.pair_override_active"
                                           : @"admin.pair_override_inherited")] value:nil]];
      if (overridden)
        [state addObject:[pages danger:[pages t:@"admin.delete_pair_override"]
                               message:[pages t:@"editor.pair_delete_confirm"] block:^{
          if ([weakSelf deleteKey:key]) [editor popPage];
        }]];
      [sections addObject:[DBEditSection title:nil fields:state]];
    }
    return sections;
  }];
}

- (DBEditPage *)strategyPage:(NSString *)identifier at:(NSString *)key {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self strategyLabel:identifier] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *strategy = @{};
    for (NSDictionary *candidate in [pages strategiesAt:key])
      if ([[candidate objectForKey:@"id"] isEqual:identifier]) strategy = candidate;
    DBEditField *enabled = [DBEditField kind:DBEditKindBool title:[pages t:@"editor.enabled"]
                                       value:[strategy objectForKey:@"enabled"] ?: @NO];
    enabled.onChange = ^BOOL(id value) {
      return [weakSelf updateStrategy:identifier at:key field:@"enabled" value:value];
    };
    DBEditField *startup = [DBEditField kind:DBEditKindNumber
                                       title:[pages t:@"admin.first_frame_timeout"]
                                       value:[strategy objectForKey:@"startup_timeout_ms"] ?: @5000];
    startup.minimum = 100;
    startup.maximum = 60000;
    startup.onChange = ^BOOL(id value) {
      return [weakSelf updateStrategy:identifier at:key field:@"startup_timeout_ms" value:value];
    };
    DBEditField *stall = [DBEditField kind:DBEditKindNumber title:[pages t:@"admin.stall_timeout"]
                                     value:[strategy objectForKey:@"stall_timeout_ms"] ?: @3000];
    stall.minimum = 1000;
    stall.maximum = 60000;
    stall.onChange = ^BOOL(id value) {
      return [weakSelf updateStrategy:identifier at:key field:@"stall_timeout_ms" value:value];
    };
    DBEditSection *section = [DBEditSection title:nil fields:@[ enabled, startup, stall ]];
    section.footer = [pages t:@"admin.playback_timeout_range"];
    return @[ section ];
  }];
}

- (NSString *)pairKey:(NSString *)receiver source:(NSString *)source {
  return [NSString stringWithFormat:@"video_playback.pairs.%@.%@", receiver, source];
}

- (NSString *)pairTitle:(NSString *)receiver source:(NSString *)source {
  return [NSString stringWithFormat:@"%@ × %@", [self deviceName:receiver],
                                    [self deviceName:source]];
}

- (DBEditPage *)playbackPolicyPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[self t:@"admin.video_playback_policy"]
                                 build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *global = [pages page:[pages t:@"admin.global"] detail:nil
                                build:^DBEditPage *{
      DBSettingsPages *inner = weakSelf;
      return [inner playbackProfilePage:@"video_playback.global" title:[inner t:@"admin.global"]
                                   pair:NO];
    }];
    DBEditSection *first = [DBEditSection title:nil fields:@[ global ]];
    first.footer = [pages t:@"admin.playback_fallback_hint"];
    NSMutableArray *pairs = [NSMutableArray array];
    NSMutableArray *keys = [NSMutableArray array];
    NSDictionary *stored = DBDict([pages at:@"video_playback.pairs"]);
    for (NSString *receiver in [[stored allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      NSDictionary *sources = DBDict([stored objectForKey:receiver]);
      for (NSString *source in [[sources allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (!DBSafeId(receiver) || !DBSafeId(source)) continue;
        NSString *key = [pages pairKey:receiver source:source];
        NSString *title = [pages pairTitle:receiver source:source];
        [keys addObject:key];
        [pairs addObject:[pages page:title detail:nil build:^DBEditPage *{
          return [weakSelf playbackProfilePage:key title:title pair:YES];
        }]];
      }
    }
    DBEditSection *overrides = [DBEditSection title:[pages t:@"admin.playback_pair_override"]
                                             fields:pairs];
    if ([keys count] > 0) {
      overrides.deleteMessage = ^NSString *(NSInteger index) {
        (void)index;
        return [weakSelf t:@"editor.pair_delete_confirm"];
      };
      overrides.onDelete = ^BOOL(NSInteger index) {
        if (index < 0 || index >= (NSInteger)[keys count]) return NO;
        return [weakSelf deleteKey:[keys objectAtIndex:(NSUInteger)index]];
      };
    }
    return @[ first, overrides ];
  }];
  // Add: pick the indoor panel that plays, then the door station it plays.
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    NSArray *receivers = [pages deviceChoicesWithRole:@"indoor_panel"];
    NSArray *sources = [pages deviceChoicesWithRole:@"door_station"];
    if ([receivers count] == 0 || [sources count] == 0) {
      [editor showMessage:[pages t:@"admin.choose_playback_pair"]];
      return;
    }
    [editor pushPage:[DBEditPage title:[pages t:@"admin.role_indoor"] build:^NSArray *{
      DBSettingsPages *outer = weakSelf;
      if (!outer) return @[];
      NSMutableArray *rows = [NSMutableArray array];
      for (NSArray *receiver in receivers) {
        NSString *receiverId = [receiver objectAtIndex:0];
        [rows addObject:[outer page:[receiver objectAtIndex:1] detail:nil
                              build:^DBEditPage *{
          return [DBEditPage title:[weakSelf t:@"admin.role_door"] build:^NSArray *{
            DBSettingsPages *middle = weakSelf;
            if (!middle) return @[];
            NSMutableArray *inner = [NSMutableArray array];
            for (NSArray *source in sources) {
              NSString *sourceId = [source objectAtIndex:0];
              [inner addObject:[middle page:[source objectAtIndex:1] detail:nil
                                      build:^DBEditPage *{
                DBSettingsPages *deep = weakSelf;
                return [deep playbackProfilePage:[deep pairKey:receiverId source:sourceId]
                                           title:[deep pairTitle:receiverId source:sourceId]
                                            pair:YES];
              }]];
            }
            return @[ [DBEditSection title:nil fields:inner] ];
          }];
        }]];
      }
      DBEditSection *section = [DBEditSection title:nil fields:rows];
      section.footer = [weakSelf t:@"admin.choose_playback_pair"];
      return @[ section ];
    }]];
  };
  return page;
}

#pragma mark - capability overrides

// A device picker in front of a per-device page.
- (DBEditPage *)devicePickerPage:(NSString *)title includeSelf:(BOOL)includeSelf
                          detail:(NSString *(^)(NSString *device))detail
                            open:(DBEditPage *(^)(NSString *device))open {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:title build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    for (NSArray *choice in [pages deviceChoicesWithRole:nil]) {
      NSString *device = [choice objectAtIndex:0];
      BOOL me = [device isEqualToString:pages.nodeId];
      if (me && !includeSelf) continue;
      NSString *name = me ? [NSString stringWithFormat:@"%@ (%@)", [choice objectAtIndex:1],
                                                       [pages t:@"editor.this_device"]]
                          : [choice objectAtIndex:1];
      [fields addObject:[pages page:name detail:(detail ? detail(device) : nil)
                              build:^DBEditPage *{ return open(device); }]];
    }
    if ([fields count] == 0)
      [fields addObject:[pages info:[pages t:@"admin.empty_devices"] value:nil]];
    return @[ [DBEditSection title:nil fields:fields] ];
  }];
}

static NSArray *DBOperationalCapabilities(void) {
  return @[ @"wan", @"mains_power", @"mqtt_reachable", @"wall_clock_sane" ];
}

- (BOOL)setCapability:(NSString *)capability value:(NSNumber *)value device:(NSString *)device {
  NSString *key = [NSString stringWithFormat:@"devices.%@.caps_override", device];
  NSMutableDictionary *next = [DBDict([self at:key]) mutableCopy];
  if (value) [next setObject:value forKey:capability];
  else [next removeObjectForKey:capability];
  return [next count] == 0 ? [self deleteKey:key] : [self setKey:key value:next];
}

// Core applies an override two ways: the four operational facts may be forced either way;
// a measured hardware feature may only be turned off, never invented.
- (DBEditPage *)capabilityPage:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *key = [NSString stringWithFormat:@"devices.%@.caps_override", device];
  return [DBEditPage title:[self deviceName:device] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *overrides = DBDict([pages at:key]);
    NSDictionary *measured = DBDict([[pages peerFor:device status:[pages statusNow]]
        objectForKey:@"caps"]);
    NSMutableArray *operational = [NSMutableArray array];
    for (NSString *capability in DBOperationalCapabilities()) {
      id stored = [overrides objectForKey:capability];
      NSString *current = stored == nil ? @"measured" : ([stored boolValue] ? @"on" : @"off");
      DBEditField *field = [DBEditField kind:DBEditKindChoice title:capability value:current];
      field.choices = @[ @[ @"measured", [pages t:@"editor.caps_measured"] ],
                         @[ @"on", [pages t:@"editor.on"] ], @[ @"off", [pages t:@"editor.off"] ] ];
      field.onChange = ^BOOL(id value) {
        NSNumber *forced = [value isEqual:@"measured"] ? nil
            : [NSNumber numberWithBool:[value isEqual:@"on"]];
        return [weakSelf setCapability:capability value:forced device:device];
      };
      [operational addObject:field];
    }
    DBEditSection *first = [DBEditSection title:[pages t:@"admin.caps_override"]
                                         fields:operational];
    first.footer = [pages t:@"editor.caps_operational_hint"];

    NSMutableSet *names = [NSMutableSet set];
    for (NSString *capability in measured) {
      id value = [measured objectForKey:capability];
      if ([value isKindOfClass:[NSNumber class]] &&
          CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue])
        [names addObject:capability];
    }
    for (NSString *capability in overrides)
      if ([[overrides objectForKey:capability] isKindOfClass:[NSNumber class]] &&
          ![[overrides objectForKey:capability] boolValue])
        [names addObject:capability];
    for (NSString *capability in DBOperationalCapabilities()) [names removeObject:capability];
    NSMutableArray *hardware = [NSMutableArray array];
    for (NSString *capability in [[names allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
      if (!DBSafeId(capability)) continue;
      id stored = [overrides objectForKey:capability];
      BOOL allowed = !(stored != nil && ![stored boolValue]);
      DBEditField *field = [DBEditField kind:DBEditKindBool title:capability
                                       value:[NSNumber numberWithBool:allowed]];
      field.onChange = ^BOOL(id value) {
        return [weakSelf setCapability:capability value:([value boolValue] ? nil : @NO)
                                device:device];
      };
      [hardware addObject:field];
    }
    NSMutableArray *sections = [NSMutableArray arrayWithObject:first];
    if ([hardware count] > 0) {
      DBEditSection *second = [DBEditSection title:[pages t:@"info.capabilities"] fields:hardware];
      second.footer = [pages t:@"editor.caps_hardware_hint"];
      [sections addObject:second];
    }
    if ([overrides count] > 0)
      [sections addObject:[DBEditSection title:nil fields:@[
          [pages danger:[pages t:@"editor.caps_clear"]
                message:[pages t:@"editor.caps_clear_confirm"] block:^{
            if ([weakSelf deleteKey:key]) [editor reloadPage];
          }] ]]];
    return sections;
  }];
}

- (DBEditPage *)capabilitiesPage {
  __weak DBSettingsPages *weakSelf = self;
  return [self devicePickerPage:[self t:@"info.capabilities"] includeSelf:YES
                         detail:^NSString *(NSString *device) {
    NSUInteger count = [DBDict([weakSelf at:[NSString stringWithFormat:
        @"devices.%@.caps_override", device]]) count];
    return count > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : nil;
  } open:^DBEditPage *(NSString *device) { return [weakSelf capabilityPage:device]; }];
}

#pragma mark - per-element UI overrides

// The manifest a device published: this node's own, or a peer's when it advertises the
// feature. Overrides are only offered for what the manifest states.
- (NSDictionary *)uiManifestFor:(NSString *)device {
  NSDictionary *status = [self statusNow];
  if ([device isEqualToString:_nodeId]) return DBDict([status objectForKey:@"ui_manifest"]);
  NSDictionary *peer = [DBConfigUtil findPeer:status nodeId:device];
  NSDictionary *features = DBDict([peer objectForKey:@"features"]);
  if ([features count] == 0)
    features = DBDict([DBDict([peer objectForKey:@"caps"]) objectForKey:@"features"]);
  if (![[features objectForKey:@"ui_manifest_v1"] boolValue]) return @{};
  return DBDict([peer objectForKey:@"ui_manifest"]);
}

- (NSString *)uiElementsKey:(NSString *)device {
  return [NSString stringWithFormat:@"devices.%@.local.ui.elements", device];
}

// value of nil removes the property; an element with nothing left is deleted.
- (BOOL)setUiProperty:(NSString *)property value:(id)value element:(NSString *)element
               device:(NSString *)device {
  NSDictionary *manifest = [self uiManifestFor:device];
  if ([DBSettingsLogic uiManifestError:manifest] != nil ||
      ![DBSettingsLogic validConfigKey:element])
    return [self refuse:[self t:@"admin.ui_manifest_unreported"]];
  if (value) {
    NSString *error = [DBSettingsLogic uiValueErrorInManifest:manifest element:element
                                                     property:property value:value];
    if (error) {
      NSDictionary *range = [DBSettingsLogic uiRangeInManifest:manifest element:element
                                                      property:property];
      return [self refuse:range
          ? [NSString stringWithFormat:@"%@ – %@", [range objectForKey:@"min"],
                                       [range objectForKey:@"max"]]
          : @"#RRGGBB"];
    }
  }
  NSString *root = [self uiElementsKey:device];
  NSMutableDictionary *next = [DBDict([DBSettingsLogic uiElementValue:DBDict([self at:root])
                                                              element:element]) mutableCopy];
  if (value) [next setObject:value forKey:property];
  else [next removeObjectForKey:property];
  NSString *key = [NSString stringWithFormat:@"%@.%@", root, element];
  return [next count] == 0 ? [self deleteKey:key] : [self setKey:key value:next];
}

- (DBEditPage *)uiElementPage:(NSString *)element device:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:element build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *manifest = [pages uiManifestFor:device];
    NSDictionary *defaults = DBDict([DBDict([DBDict([manifest objectForKey:@"elements"])
        objectForKey:element]) objectForKey:@"defaults"]);
    NSDictionary *stored = DBDict([DBSettingsLogic uiElementValue:
        DBDict([pages at:[pages uiElementsKey:device]]) element:element]);
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *property in [DBSettingsLogic uiPropertiesInManifest:manifest element:element]) {
      NSString *title = [pages t:[@"editor.ui_prop_" stringByAppendingString:property]];
      id override = [stored objectForKey:property];
      if ([DBSettingsLogic uiPropertyIsColor:property]) {
        NSString *hex = [override isKindOfClass:[NSString class]] ? override : nil;
        NSString *fallback = [[defaults objectForKey:property] isKindOfClass:[NSString class]]
            ? [defaults objectForKey:property] : @"";
        DBEditField *color = [DBEditField kind:DBEditKindColor title:title value:hex ?: fallback];
        color.detail = hex ?: [pages t:@"editor.automatic"];
        color.onChange = ^BOOL(id value) {
          return [weakSelf setUiProperty:property value:[[value description] uppercaseString]
                                 element:element device:device];
        };
        [fields addObject:color];
        if (hex)
          [fields addObject:[pages action:[NSString stringWithFormat:@"%@: %@", title,
                                              [pages t:@"editor.automatic"]]
                                    block:^{
            if ([weakSelf setUiProperty:property value:nil element:element device:device])
              [editor reloadPage];
          }]];
        continue;
      }
      NSDictionary *range = [DBSettingsLogic uiRangeInManifest:manifest element:element
                                                      property:property];
      DBEditField *number = [DBEditField kind:DBEditKindText title:title
          value:[override isKindOfClass:[NSNumber class]] ? [override stringValue] : @""];
      number.detail = [override isKindOfClass:[NSNumber class]] ? [override stringValue]
                                                                : [pages t:@"editor.automatic"];
      number.keyboard = UIKeyboardTypeNumbersAndPunctuation;
      number.placeholder = [NSString stringWithFormat:@"%@ – %@", [range objectForKey:@"min"],
                                                      [range objectForKey:@"max"]];
      number.onChange = ^BOOL(id value) {
        NSString *text = DBTrim([value description] ?: @"");
        // An empty entry returns the property to the device's own default.
        if ([text length] == 0)
          return [weakSelf setUiProperty:property value:nil element:element device:device];
        NSScanner *scanner = [NSScanner scannerWithString:text];
        double parsed = 0;
        id entered = [scanner scanDouble:&parsed] && [scanner isAtEnd]
            ? [NSNumber numberWithDouble:parsed] : (id)text;
        return [weakSelf setUiProperty:property value:entered element:element device:device];
      };
      [fields addObject:number];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"editor.ui_element_hint"];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:section];
    if ([stored count] > 0)
      [sections addObject:[DBEditSection title:nil fields:@[
          [pages danger:[pages t:@"editor.reset"]
                message:[pages t:@"editor.ui_element_reset_confirm"] block:^{
            DBSettingsPages *inner = weakSelf;
            if (![DBSettingsLogic validConfigKey:element]) return;
            if ([inner deleteKey:[NSString stringWithFormat:@"%@.%@",
                                     [inner uiElementsKey:device], element]])
              [editor reloadPage];
          }] ]]];
    return sections;
  }];
}

- (DBEditPage *)uiElementsPageFor:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self deviceName:device] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSDictionary *manifest = [pages uiManifestFor:device];
    if ([DBSettingsLogic uiManifestError:manifest] != nil)
      return @[ [DBEditSection title:nil fields:@[
          [pages info:[pages t:@"admin.ui_manifest_unreported"] value:nil] ]] ];
    NSDictionary *elements = DBDict([manifest objectForKey:@"elements"]);
    NSDictionary *stored = DBDict([pages at:[pages uiElementsKey:device]]);
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *element in [[elements allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      NSUInteger count = [DBDict([DBSettingsLogic uiElementValue:stored element:element]) count];
      NSString *detail = count > 0 ? [NSString stringWithFormat:@"%lu", (unsigned long)count]
                                   : [pages t:@"editor.automatic"];
      [fields addObject:[pages page:element detail:detail build:^DBEditPage *{
        return [weakSelf uiElementPage:element device:device];
      }]];
    }
    DBEditSection *section = [DBEditSection title:[pages t:@"admin.native_ui"] fields:fields];
    section.footer = [pages t:@"admin.ui_manifest_readonly"];
    return @[ section ];
  }];
}

- (DBEditPage *)uiElementsPage {
  __weak DBSettingsPages *weakSelf = self;
  return [self devicePickerPage:[self t:@"admin.native_ui"] includeSelf:YES
                         detail:^NSString *(NSString *device) {
    DBSettingsPages *pages = weakSelf;
    return [DBSettingsLogic uiManifestError:[pages uiManifestFor:device]] == nil
        ? nil : [pages t:@"power.unknown"];
  } open:^DBEditPage *(NSString *device) { return [weakSelf uiElementsPageFor:device]; }];
}

#pragma mark - raw configuration

// A reference key holds "secret:<name>" or nothing; a raw write must never put the secret
// itself into replicated configuration.
static BOOL DBRawValueAllowed(NSString *key, id value) {
  if (![key hasSuffix:@"_ref"] || ![value isKindOfClass:[NSString class]]) return YES;
  return [(NSString *)value length] == 0 || [(NSString *)value hasPrefix:@"secret:"];
}

// One key, after the operator has seen exactly what will be stored.
- (void)writeRawKey:(NSString *)key json:(NSString *)json then:(void (^)(void))then {
  id value = nil;
  if (![DBSettingsLogic validConfigKey:key]) {
    [_editor showMessage:[self t:@"editor.raw_key_invalid"]];
    return;
  }
  if (![DBSettingsLogic parseJsonValue:json into:&value]) {
    [_editor showMessage:[self t:@"admin.valid_json_required"]];
    return;
  }
  if (!DBRawValueAllowed(key, value)) {
    [_editor showMessage:[self t:@"editor.raw_secret_refused"]];
    return;
  }
  __weak DBSettingsPages *weakSelf = self;
  [_editor confirmTitle:key
                message:[NSString stringWithFormat:@"%@\n%@", [self t:@"editor.raw_write_confirm"],
                                                   [DBSettingsLogic compactJson:value]]
                   then:^{
    DBSettingsPages *pages = weakSelf;
    if (pages && [pages setKey:key value:value] && then) then();
  }];
}

- (DBEditPage *)rawConfigPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  __block NSArray *leaves = nil;
  static const NSUInteger kShown = 200;
  DBEditPage *page = [DBEditPage title:[self t:@"editor.raw_config"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    if (leaves == nil) leaves = [DBSettingsLogic flattenConfig:[pages cfg]];
    NSString *needle = [DBTrim(editor.filterText ?: @"") lowercaseString];
    NSMutableArray *fields = [NSMutableArray array];
    NSMutableArray *keys = [NSMutableArray array];
    NSUInteger matches = 0;
    for (NSArray *leaf in leaves) {
      NSString *key = [leaf objectAtIndex:0];
      NSString *json = [leaf objectAtIndex:1];
      if ([needle length] > 0 &&
          [[key lowercaseString] rangeOfString:needle].location == NSNotFound &&
          [[json lowercaseString] rangeOfString:needle].location == NSNotFound)
        continue;
      matches++;
      if ([fields count] >= kShown) continue;
      DBEditField *field = [DBEditField kind:DBEditKindText title:key value:json];
      field.keyboard = UIKeyboardTypeASCIICapable;
      field.onChange = ^BOOL(id value) {
        [weakSelf writeRawKey:key json:[value description] then:^{
          leaves = nil;
          [editor reloadPage];
        }];
        return NO;
      };
      [fields addObject:field];
      [keys addObject:key];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = matches > kShown
        ? [pages->_texts t:@"editor.raw_more",
              [NSString stringWithFormat:@"%lu", (unsigned long)kShown],
              [NSString stringWithFormat:@"%lu", (unsigned long)matches], nil]
        : [pages t:@"editor.raw_hint"];
    section.deleteMessage = ^NSString *(NSInteger index) {
      (void)index;
      return [weakSelf t:@"editor.raw_delete_confirm"];
    };
    section.onDelete = ^BOOL(NSInteger index) {
      if (index < 0 || index >= (NSInteger)[keys count]) return NO;
      if (![weakSelf deleteKey:[keys objectAtIndex:(NSUInteger)index]]) return NO;
      leaves = nil;
      return YES;
    };
    return @[ section ];
  }];
  page.searchable = YES;
  page.filtersItself = YES;
  page.searchPlaceholder = [self t:@"admin.key"];
  page.onAppear = ^{ leaves = nil; };
  page.onAdd = ^{
    DBSettingsPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"admin.key"] value:@"" placeholder:@"ui.ringtone"
               keyboard:UIKeyboardTypeASCIICapable secure:NO then:^(NSString *key) {
      NSString *name = DBTrim(key);
      if (![DBSettingsLogic validConfigKey:name]) {
        [editor showMessage:[weakSelf t:@"editor.raw_key_invalid"]];
        return;
      }
      [editor promptTitle:name value:@"" placeholder:@"\"text\", 12, true, {…}"
                 keyboard:UIKeyboardTypeASCIICapable secure:NO then:^(NSString *json) {
        [weakSelf writeRawKey:name json:json then:^{
          leaves = nil;
          [editor reloadPage];
        }];
      }];
    }];
  };
  return page;
}

#pragma mark - logs and the event log

static const NSUInteger kDBLogPage = 50;

- (DBEditPage *)coreLogPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  __block NSArray *lines = nil;
  __block NSUInteger shown = kDBLogPage;
  void (^load)(void) = ^{
    [weakSelf adminRequest:@"GET" path:@"/api/logs" body:nil
                      then:^(NSInteger status, NSDictionary *json) {
      if (status != 200) {
        [weakSelf showFailure:json];
        return;
      }
      // Core returns oldest first; the page reads newest first.
      lines = [[DBArray([json objectForKey:@"logs"]) reverseObjectEnumerator] allObjects];
      [editor reloadPage];
    }];
  };
  DBEditPage *page = [DBEditPage title:[self t:@"admin.logs"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    if (lines == nil) [fields addObject:[pages info:[pages t:@"editor.loading"] value:nil]];
    NSUInteger count = MIN(shown, [lines count]);
    for (NSUInteger i = 0; i < count; i++)
      [fields addObject:[pages info:[[lines objectAtIndex:i] description] value:nil]];
    NSMutableArray *actions = [NSMutableArray array];
    if ([lines count] > count)
      [actions addObject:[pages action:[pages t:@"editor.show_older"] block:^{
        shown += kDBLogPage;
        [editor reloadPage];
      }]];
    [actions addObject:[pages action:[pages t:@"admin.refresh"] block:^{
      shown = kDBLogPage;
      load();
    }]];
    return @[ [DBEditSection title:nil fields:fields], [DBEditSection title:nil fields:actions] ];
  }];
  page.searchable = YES;
  page.onAppear = load;
  return page;
}

- (NSArray *)eventTypeChoices {
  NSMutableArray *choices = [NSMutableArray arrayWithObject:@[ @"", [self t:@"editor.all"] ]];
  for (NSString *type in @[ @"press", @"motion", @"reply", @"answered", @"missed", @"offline",
                            @"online", @"config_changed", @"dtmf_action", @"cluster_key_changed",
                            @"peer_rejected" ])
    [choices addObject:@[ type, [self eventTypeLabel:type] ]];
  return choices;
}

- (NSString *)eventTypeLabel:(NSString *)type {
  for (NSString *prefix in @[ @"admin.event_", @"panel.event_" ]) {
    NSString *key = [prefix stringByAppendingString:type ?: @""];
    NSString *label = [self t:key];
    if (![label isEqualToString:key]) return label;
  }
  return type ?: @"";
}

- (DBEditPage *)eventLogPage {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  __block NSArray *events = nil;
  __block NSInteger limit = 100;
  __block NSString *filter = @"";
  __block NSInteger offsetMinutes = 0;
  void (^load)(void) = ^{
    NSString *path = [NSString stringWithFormat:@"/api/events?limit=%ld", (long)limit];
    if ([filter length] > 0) path = [path stringByAppendingFormat:@"&type=%@", filter];
    [weakSelf adminRequest:@"GET" path:path body:nil
                      then:^(NSInteger status, NSDictionary *json) {
      DBSettingsPages *pages = weakSelf;
      if (status != 200) {
        [pages showFailure:json];
        return;
      }
      offsetMinutes = [DBConfigUtil intVal:[pages->_core localTimeJson:0] path:@"offset_min"
                                       def:0];
      events = DBArray([json objectForKey:@"events"]);
      [editor reloadPage];
    }];
  };
  DBEditPage *page = [DBEditPage title:[self t:@"admin.events"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditField *type = [DBEditField kind:DBEditKindChoice title:[pages t:@"admin.filter_type"]
                                    value:filter];
    type.choices = [pages eventTypeChoices];
    type.onChange = ^BOOL(id value) {
      filter = [[value description] copy];
      limit = 100;
      load();
      return YES;
    };
    NSDictionary *doors = DBDict([pages at:@"doors"]);
    NSMutableArray *fields = [NSMutableArray array];
    if (events == nil) [fields addObject:[pages info:[pages t:@"editor.loading"] value:nil]];
    else if ([events count] == 0)
      [fields addObject:[pages info:[pages t:([filter length] > 0 ? @"admin.empty_events_filtered"
                                                                  : @"admin.empty_events")]
                              value:nil]];
    // Core answers newest first.
    for (id candidate in events) {
      NSDictionary *event = DBDict(candidate);
      long long wall = [DBConfigUtil longLongVal:event path:@"wall_ms" def:0];
      NSString *when = [NSString stringWithFormat:@"%@ %@",
          [DBCallHistoryModel dayKeyForTs:wall offsetMinutes:offsetMinutes],
          [DBCallHistoryModel clockForTs:wall offsetMinutes:offsetMinutes]];
      NSString *door = [DBConfigUtil evStr:event key:@"door"];
      NSString *device = [DBConfigUtil evStr:event key:@"device"];
      NSMutableArray *about = [NSMutableArray array];
      if ([door length] > 0) [about addObject:[pages label:[doors objectForKey:door] fallback:door]];
      if ([device length] > 0) [about addObject:[pages deviceName:device]];
      NSString *payload = [DBConfigUtil evStr:event key:@"payload"];
      if ([payload length] > 2) [about addObject:payload];
      [fields addObject:[pages info:[NSString stringWithFormat:@"%@  %@", when,
                                        [pages eventTypeLabel:[DBConfigUtil evStr:event key:@"type"]]]
                              value:[about componentsJoinedByString:@" · "]]];
    }
    NSMutableArray *actions = [NSMutableArray array];
    if ((NSInteger)[events count] >= limit && limit < 1000)
      [actions addObject:[pages action:[pages t:@"editor.show_older"] block:^{
        limit = MIN((NSInteger)1000, limit + 100);
        load();
      }]];
    [actions addObject:[pages action:[pages t:@"admin.refresh"] block:load]];
    return @[ [DBEditSection title:nil fields:@[ type ]], [DBEditSection title:nil fields:fields],
              [DBEditSection title:nil fields:actions] ];
  }];
  page.onAppear = load;
  return page;
}

- (DBEditPage *)logsPage {
  __weak DBSettingsPages *weakSelf = self;
  return [DBEditPage title:[self t:@"admin.logs"] build:^NSArray *{
    DBSettingsPages *pages = weakSelf;
    DBEditSection *section = [DBEditSection title:nil fields:@[
      [pages page:[pages t:@"admin.events"] detail:nil
            build:^DBEditPage *{ return [weakSelf eventLogPage]; }],
      [pages page:[pages t:@"admin.logs"] detail:nil
            build:^DBEditPage *{ return [weakSelf coreLogPage]; }] ]];
    section.footer = [pages t:@"editor.logs_hint"];
    return @[ section ];
  }];
}

#pragma mark - another device's own settings

// The devices.<id>.local.* settings the web admin edits per device. Every key has this one
// implementation, whichever device it is opened for.
- (NSArray *)deviceLocalSections:(NSString *)device {
  __weak DBSettingsPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSString *local = [NSString stringWithFormat:@"devices.%@.local", device];
  NSString *(^key)(NSString *) = ^NSString *(NSString *leaf) {
    return [NSString stringWithFormat:@"%@.%@", local, leaf];
  };
  NSDictionary *cfg = [self cfg];
  BOOL doorStation = [[DBConfigUtil str:cfg path:[NSString stringWithFormat:@"devices.%@.role",
                                                     device]] isEqualToString:@"door_station"];
  NSMutableArray *sections = [NSMutableArray array];

  DBEditField *language = [self choice:[self t:@"settings.ui_lang"] key:key(@"ui_lang") def:@"ja"
                               choices:[self langChoices]];
  DBEditField *helper = [self choice:[self t:@"settings.helper_mode"]
                                 key:key(@"recovery.helper_mode") def:@"auto"
                             choices:@[ @[ @"auto", [self t:@"admin.helper_auto"] ],
                                        @[ @"on", [self t:@"admin.helper_on"] ],
                                        @[ @"off", [self t:@"admin.helper_off"] ] ]];
  [sections addObject:[DBEditSection title:nil fields:@[ language, helper ]]];

  // Call return: the cluster value until this device overrides it.
  NSString *returnKey = key(@"call.return_s");
  NSInteger clusterReturn = [DBConfigUtil intVal:cfg path:@"call.indoor.return_s" def:60];
  BOOL returnOverridden = [[self at:returnKey] isKindOfClass:[NSNumber class]];
  DBEditField *inheritReturn = [DBEditField kind:DBEditKindBool
                                           title:[self t:@"call.return_inherit"]
                                           value:[NSNumber numberWithBool:!returnOverridden]];
  inheritReturn.onChange = ^BOOL(id value) {
    return [value boolValue] ? [weakSelf deleteKey:returnKey]
        : [weakSelf setKey:returnKey value:[NSNumber numberWithInteger:clusterReturn]];
  };
  NSMutableArray *callFields = [NSMutableArray arrayWithObject:inheritReturn];
  if (returnOverridden)
    [callFields addObject:[self number:[self t:@"call.return_s"] key:returnKey def:clusterReturn
                                   min:5 max:600]];
  else
    [callFields addObject:[self info:[self t:@"call.return_s"]
                               value:[NSString stringWithFormat:@"%ld", (long)clusterReturn]]];
  DBEditSection *callSection = [DBEditSection title:[self t:@"call.return_title"]
                                             fields:callFields];
  callSection.footer = [self t:@"call.return_invalid"];
  [sections addObject:callSection];

  DBEditField *playback = [self choice:[self t:@"settings.video_playback"]
                                   key:key(@"video.playback") def:@"low_latency"
                               choices:@[ @[ @"low_latency", [self t:@"prefs.playback_low_latency"] ],
                                          @[ @"hls", [self t:@"admin.video_hls"] ],
                                          @[ @"mjpeg", [self t:@"settings.playback_mjpeg"] ] ]];
  DBEditField *rotation = [self choice:[self t:@"settings.video_rotation"]
                                   key:key(@"video.rotation") def:@"auto"
                               choices:@[ @[ @"auto", [self t:@"admin.rotation_auto"] ],
                                          @[ @"0", @"0°" ], @[ @"90", @"90°" ],
                                          @[ @"180", @"180°" ], @[ @"270", @"270°" ] ]];
  [sections addObject:[DBEditSection title:nil fields:@[ playback, rotation ]]];

  if (doorStation) {
    NSMutableArray *layouts = [NSMutableArray array];
    for (NSString *layout in @[ @"standard", @"left", @"right", @"edges" ])
      [layouts addObject:@[ layout,
          [self t:[@"settings.visitor_layout_" stringByAppendingString:layout]] ]];
    DBEditField *layout = [self choice:[self t:@"settings.visitor_layout"]
                                   key:key(@"visitor_layout") def:@"standard" choices:layouts];
    [sections addObject:[DBEditSection title:nil fields:@[ layout ]]];

    DBEditField *codec = [self choice:[self t:@"settings.cam_codec"] key:key(@"camera.codec")
                                  def:@"auto"
                              choices:@[ @[ @"auto", [self t:@"admin.codec_auto"] ],
                                         @[ @"mjpeg", [self t:@"settings.codec_mjpeg"] ],
                                         @[ @"h264", [self t:@"settings.codec_h264"] ] ]];
    DBEditField *(^resolution)(NSString *, NSString *, NSString *) =
        ^DBEditField *(NSString *title, NSString *leaf, NSString *def) {
      NSString *leafKey = key(leaf);
      DBEditField *field = [DBEditField kind:DBEditKindText title:title
                                       value:[DBConfigUtil str:cfg path:leafKey] ?: def];
      field.keyboard = UIKeyboardTypeNumbersAndPunctuation;
      field.placeholder = def;
      field.onChange = ^BOOL(id value) {
        NSString *text = [DBTrim([value description] ?: @"") lowercaseString];
        NSArray *parts = [text componentsSeparatedByString:@"x"];
        if ([parts count] != 2 || [[parts objectAtIndex:0] integerValue] < 16 ||
            [[parts objectAtIndex:1] integerValue] < 16)
          return [weakSelf refuse:def];
        return [weakSelf setKey:leafKey
                          value:[NSString stringWithFormat:@"%ldx%ld",
                                    (long)[[parts objectAtIndex:0] integerValue],
                                    (long)[[parts objectAtIndex:1] integerValue]]];
      };
      return field;
    };
    DBEditField *hint = [self text:[self t:@"settings.cam_hint"] key:key(@"camera.device_hint")];
    DBEditSection *camera = [DBEditSection title:[self t:@"prefs.camera"] fields:@[
      codec,
      resolution([self t:@"settings.cam_resolution"], @"camera.resolution", @"640x480"),
      [self number:[self t:@"settings.cam_fps"] key:key(@"camera.mjpeg_fps") def:8 min:1 max:30],
      [self number:[self t:@"settings.cam_quality"] key:key(@"camera.mjpeg_quality") def:60
               min:1 max:100],
      resolution([self t:@"settings.cam_h264_resolution"], @"camera.h264_resolution", @"640x360"),
      [self number:[self t:@"settings.cam_h264_fps"] key:key(@"camera.h264_fps") def:30
               min:1 max:60],
      [self number:[self t:@"settings.cam_h264_bitrate"] key:key(@"camera.h264_bitrate_kbps")
               def:700 min:100 max:8000],
      hint ]];
    camera.footer = [self t:@"prefs.camera_codec_footer"];
    [sections addObject:camera];

    [sections addObject:[DBEditSection title:[self t:@"prefs.motion"] fields:@[
      [self toggle:[self t:@"settings.motion_enabled"] key:key(@"motion.enabled") def:YES],
      [self toggle:[self t:@"admin.motion_wake_screen"] key:key(@"motion.wake_screen") def:NO],
      [self number:[self t:@"settings.motion_sensitivity"] key:key(@"motion.sensitivity") def:40
               min:0 max:100],
      [self number:[self t:@"settings.motion_interval"] key:key(@"motion.min_interval_s") def:30
               min:0 max:3600] ]]];
  }

  // Volumes: each level inherits audio.volume until this device overrides it.
  NSDictionary *audio = [_core audioJsonForDevice:device];
  NSMutableArray *volumes = [NSMutableArray array];
  BOOL anyOverride = NO;
  for (NSString *level in @[ @"call", @"sos", @"idle" ]) {
    NSString *levelKey = key([@"audio.volume." stringByAppendingString:level]);
    BOOL overridden = [[self at:levelKey] isKindOfClass:[NSNumber class]];
    if (overridden) anyOverride = YES;
    NSInteger effective = overridden ? [DBConfigUtil intVal:cfg path:levelKey def:0]
        : [DBConfigUtil intVal:audio path:level
                           def:[DBConfigUtil intVal:cfg
                                               path:[@"audio.volume." stringByAppendingString:level]
                                                def:80]];
    DBEditField *field = [self number:[self t:[@"volume." stringByAppendingString:level]]
                                  key:levelKey def:effective min:0 max:100];
    if (!overridden)
      field.detail = [NSString stringWithFormat:@"%ld  (%@)", (long)effective,
                                                [self t:@"volume.inherit"]];
    [volumes addObject:field];
  }
  if (anyOverride)
    [volumes addObject:[self danger:[self t:@"settings.volume_reset"]
                            message:[self t:@"settings.volume_reset_desc"] block:^{
      if ([weakSelf deleteKey:key(@"audio.volume")]) [editor reloadPage];
    }]];
  [sections addObject:[DBEditSection title:[self t:@"volume.title"] fields:volumes]];

  [sections addObject:[DBEditSection title:nil fields:@[
      [self page:[self t:@"settings.theme_bg"]
          detail:[DBConfigUtil str:cfg path:key(@"theme.bg_color")] ?: [self t:@"editor.inherited"]
           build:^DBEditPage *{ return [weakSelf themeScopePage:device]; }] ]]];
  return sections;
}

- (DBEditPage *)otherDevicesPage {
  __weak DBSettingsPages *weakSelf = self;
  return [self devicePickerPage:[self t:@"settings.page_other_devices"] includeSelf:NO
                         detail:^NSString *(NSString *device) {
    DBSettingsPages *pages = weakSelf;
    return [pages roleLabel:[DBConfigUtil str:[pages cfg]
        path:[NSString stringWithFormat:@"devices.%@.role", device]]];
  } open:^DBEditPage *(NSString *device) {
    DBSettingsPages *pages = weakSelf;
    DBEditPage *page = [DBEditPage title:[pages deviceName:device] build:^NSArray *{
      return [weakSelf deviceLocalSections:device] ?: @[];
    }];
    return page;
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
