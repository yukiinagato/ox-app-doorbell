#import "DBFlowEditorPages.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBFlowOrder.h"
#import "../Core/DBGeneratedStrings.h"
#import "../Core/DBIconAsset.h"
#import "../Core/DBPurposeModel.h"
#import "../Core/DBTexts.h"
#import "../Core/DBVisitorFlowModel.h"
#import "DBEditor.h"
#import "DBRouter.h"

static NSDictionary *DBFDict(id value) {
  return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static NSArray *DBFArray(id value) {
  return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static NSString *DBFString(id value) {
  return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSString *DBFTrim(NSString *text) {
  return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// A deep mutable copy of a JSON value, so one member of a step can change before the whole step
// is written back.
static id DBFMutable(id value) {
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
    for (id key in (NSDictionary *)value) [copy setObject:DBFMutable([value objectForKey:key]) forKey:key];
    return copy;
  }
  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableArray *copy = [NSMutableArray array];
    for (id item in (NSArray *)value) [copy addObject:DBFMutable(item)];
    return copy;
  }
  return value;
}

static NSString *DBFRandomHex(NSUInteger bytes) {
  NSMutableData *data = [NSMutableData dataWithLength:bytes];
  if (SecRandomCopyBytes(kSecRandomDefault, bytes, (uint8_t *)[data mutableBytes]) != 0) return @"x";
  NSMutableString *hex = [NSMutableString stringWithCapacity:bytes * 2];
  const uint8_t *p = (const uint8_t *)[data bytes];
  for (NSUInteger i = 0; i < bytes; i++) [hex appendFormat:@"%02x", p[i]];
  return hex;
}

static const NSUInteger kTitleLimit = 60;
static const NSUInteger kBodyLimit = 600;
static const NSUInteger kLabelLimit = 40;
static const NSUInteger kMessageLimit = 200;
static const NSUInteger kAltLimit = 120;

@interface DBFlowEditorPages () <UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                                 UIPopoverControllerDelegate>
@end

@implementation DBFlowEditorPages {
  __weak DBRouter *_router;
  __weak DBEditorView *_editor;
  DBCoreBridge *_core;
  DBTexts *_texts;
  DBBootConfig *_boot;
  NSDictionary *_cfg;
  NSDictionary *_preview;
  DBVisitorFlowModel *_sim;
  NSString *_simLang;
  NSString *_simResult;
  UIPopoverController *_popover;
  UIImagePickerController *_picker;
  void (^_pickerDone)(NSString *hash);
}

- (id)initWithRouter:(DBRouter *)router editor:(DBEditorView *)editor {
  self = [super init];
  if (self) {
    _router = router;
    _editor = editor;
    _core = router.core;
    _texts = router.texts;
    _boot = router.boot;
  }
  return self;
}

- (void)close {
  _preview = nil;
  _sim = nil;
  _simResult = nil;
  [_popover dismissPopoverAnimated:NO];
  _popover = nil;
  _picker.delegate = nil;
  _picker = nil;
  _pickerDone = nil;
}

#pragma mark - configuration

- (NSString *)t:(NSString *)key {
  return [_texts ts:key];
}

- (NSString *)lang {
  return [_boot.uiLang length] > 0 ? _boot.uiLang : @"ja";
}

- (NSDictionary *)cfg {
  NSDictionary *fresh = [_core config];
  if ([fresh isKindOfClass:[NSDictionary class]]) _cfg = fresh;
  return _cfg ?: @{};
}

- (NSDictionary *)flow {
  return _preview ?: DBFDict([[self cfg] objectForKey:@"visitor_flow"]);
}

- (void)usePreviewTemplate {
  _preview = DBFDict([[_core visitorFlowTemplateJson:@"default"] objectForKey:@"flow"]);
}

- (NSDictionary *)steps {
  return DBFDict([[self flow] objectForKey:@"steps"]);
}

- (NSDictionary *)step:(NSString *)stepID {
  return DBFDict([[self steps] objectForKey:stepID ?: @""]);
}

// The languages a visitor can pick, in the order the configuration lists them.
- (NSArray *)languages {
  NSMutableArray *languages = [NSMutableArray array];
  for (id value in DBFArray([DBConfigUtil dig:[self cfg] path:@"ui.languages"]))
    if ([value isKindOfClass:[NSString class]] && [value length] > 0 &&
        ![languages containsObject:value]) [languages addObject:value];
  return [languages count] > 0 ? languages : @[ @"ja", @"en", @"zh" ];
}

- (NSString *)kindLabel:(NSString *)kind {
  NSString *key = [@"flow_editor.kind_" stringByAppendingString:kind ?: @""];
  NSString *text = [self t:key];
  return [text isEqualToString:key] ? (kind ?: @"") : text;
}

- (NSString *)text:(id)map {
  NSDictionary *labels = DBFDict(map);
  for (NSString *key in @[ [self lang], @"ja" ]) {
    NSString *value = DBFString([labels objectForKey:key]);
    if ([value length] > 0) return value;
  }
  for (id value in [labels allValues])
    if ([DBFString(value) length] > 0) return value;
  return @"";
}

- (NSString *)purposeLabel:(NSString *)purpose {
  NSDictionary *entry = DBFDict([DBConfigUtil dig:[self cfg]
      path:[@"visit_purposes." stringByAppendingString:purpose ?: @""]]);
  NSString *label = [self text:[entry objectForKey:@"label"]];
  return [label length] > 0 ? label : (purpose ?: @"");
}

// A short name for a step in lists and pickers.
- (NSString *)stepName:(NSString *)stepID {
  NSDictionary *step = [self step:stepID];
  NSString *kind = DBFString([step objectForKey:@"kind"]);
  NSString *name = [self text:[step objectForKey:@"title"]];
  if ([name length] == 0) name = [self text:[step objectForKey:@"message"]];
  if ([name length] == 0 && [DBFString([step objectForKey:@"purpose"]) length] > 0)
    name = [self purposeLabel:[step objectForKey:@"purpose"]];
  if ([name length] == 0) name = stepID;
  return [NSString stringWithFormat:@"%@: %@", [self kindLabel:kind], name];
}

// Core's step_order for the stored steps: the administrator's order first, then reading order.
- (NSArray *)orderedStepIDs {
  return [DBFlowOrder stepOrderForFlow:[self flow]];
}

// The batch that stores new steps (id to whole step) and the consecutive `order` values the new
// sequence needs. New steps follow `afterID` in the given order, or the end of the list.
- (NSArray *)opsForNewSteps:(NSDictionary *)newSteps ids:(NSArray *)newIDs after:(NSString *)afterID {
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:[self steps]];
  [all addEntriesFromDictionary:newSteps];
  NSArray *sequence = [self orderedStepIDs];
  NSString *previous = afterID;
  for (NSString *stepID in newIDs) {
    sequence = [DBFlowOrder sequence:sequence inserting:stepID after:previous];
    previous = stepID;
  }
  NSMutableDictionary *ordered = [NSMutableDictionary dictionary];
  for (NSDictionary *write in [DBFlowOrder writesForSequence:sequence steps:all])
    [ordered setObject:[write objectForKey:@"step"] forKey:[write objectForKey:@"id"]];
  NSMutableArray *ops = [NSMutableArray array];
  for (NSString *stepID in newIDs)
    [ops addObject:[self setOp:[@"visitor_flow.steps." stringByAppendingString:stepID]
                         value:[ordered objectForKey:stepID] ?: [newSteps objectForKey:stepID]]];
  for (NSString *stepID in sequence)
    if ([newSteps objectForKey:stepID] == nil && [ordered objectForKey:stepID] != nil)
      [ops addObject:[self setOp:[@"visitor_flow.steps." stringByAppendingString:stepID]
                           value:[ordered objectForKey:stepID]]];
  return ops;
}

- (NSArray *)stepChoicesOfKind:(NSString *)kind {
  NSMutableArray *choices = [NSMutableArray array];
  for (NSString *stepID in [self orderedStepIDs])
    if (kind == nil || [DBFString([[self step:stepID] objectForKey:@"kind"]) isEqualToString:kind])
      [choices addObject:@[ stepID, [self stepName:stepID] ]];
  return choices;
}

- (NSArray *)stepsReferencing:(NSString *)stepID {
  NSMutableArray *names = [NSMutableArray array];
  NSDictionary *steps = [self steps];
  for (NSString *other in [self orderedStepIDs]) {
    if ([other isEqualToString:stepID]) continue;
    NSDictionary *step = DBFDict([steps objectForKey:other]);
    BOOL refers = [DBFString([step objectForKey:@"to"]) isEqualToString:stepID] ||
        [DBFString([step objectForKey:@"on_unanswered"]) isEqualToString:stepID];
    for (NSDictionary *option in DBFArray([step objectForKey:@"options"]))
      if ([DBFString([DBFDict(option) objectForKey:@"to"]) isEqualToString:stepID]) refers = YES;
    if (refers) [names addObject:other];
  }
  return names;
}

#pragma mark - writing

- (NSDictionary *)setOp:(NSString *)key value:(id)value {
  return @{ @"op" : @"set", @"key" : key, @"value" : value ?: [NSNull null] };
}

- (NSDictionary *)deleteOp:(NSString *)key {
  return @{ @"op" : @"delete", @"key" : key };
}

// Core's error names the rule and, after ": ", the step or option it concerns. The text before
// the colon is the i18n key; anything unknown falls back to the generic message.
- (NSString *)explainError:(NSString *)error {
  NSRange split = [error rangeOfString:@": "];
  NSString *code = split.location == NSNotFound ? error : [error substringToIndex:split.location];
  NSString *detail = split.location == NSNotFound ? @"" : [error substringFromIndex:NSMaxRange(split)];
  NSString *text = [self t:code];
  if ([text isEqualToString:code]) {
    text = [_texts t:@"visitor_flow.invalid", [error length] > 0 ? error : code, nil];
    return text;
  }
  return [detail length] > 0 ? [NSString stringWithFormat:@"%@\n%@", text, detail] : text;
}

// One whole edit as one batch. The graph is validated on the configuration the batch leaves, so a
// step and the step it points to arrive together.
- (BOOL)commit:(NSArray *)ops {
  if ([ops count] == 0) return YES;
  DBEditorView *editor = _editor;
  if (_preview != nil) {
    [editor showMessage:[self t:@"settings.save_failed"]];
    return NO;
  }
  NSDictionary *result = [_core writeConfigBatch:ops];
  if (result == nil) {
    [editor showMessage:[self t:@"editor.core_too_old"]];
    return NO;
  }
  if ([[result objectForKey:@"ok"] boolValue]) {
    NSMutableArray *warnings = [NSMutableArray array];
    for (id warning in DBFArray([result objectForKey:@"warnings"])) {
      NSString *key = DBFString([DBFDict(warning) objectForKey:@"message_key"]);
      NSString *text = [self t:key];
      if ([key length] > 0 && ![text isEqualToString:key]) [warnings addObject:text];
    }
    [editor showMessage:[warnings count] > 0
        ? [_texts t:@"settings.saved_with_warning", [warnings componentsJoinedByString:@" "], nil]
        : [self t:@"settings.saved"]];
    return YES;
  }
  NSString *error = DBFString([result objectForKey:@"err"]);
  if ([error length] == 0) error = DBFString([result objectForKey:@"error"]);
  if ([error isEqualToString:@"admin_required"] ||
      [DBFString([result objectForKey:@"error_code"]) isEqualToString:@"admin_required"]) {
    __weak DBFlowEditorPages *weakSelf = self;
    [_router requestPinThen:^{
      DBFlowEditorPages *pages = weakSelf;
      if (pages && [pages commit:ops]) [editor reloadPage];
    }];
    return NO;
  }
  // An unresolved conflict is a decision for the administrator; it is never retried here.
  if ([error isEqualToString:@"unresolved_config_conflict"] ||
      [error isEqualToString:@"stale_config_resolution"]) {
    [editor showMessage:[self t:@"flow_editor.conflict"]];
    return NO;
  }
  [editor showMessage:[NSString stringWithFormat:@"%@\n%@", [self t:@"settings.save_failed"],
                                                 [self explainError:error]]];
  return NO;
}

- (BOOL)setLeaf:(NSString *)name value:(id)value {
  return [self commit:@[ [self setOp:[@"visitor_flow." stringByAppendingString:name] value:value] ]];
}

- (BOOL)writeStep:(NSString *)stepID value:(NSDictionary *)step {
  return [self commit:@[ [self setOp:[@"visitor_flow.steps." stringByAppendingString:stepID]
                               value:step] ]];
}

// Reads the step as it is now, lets the block change a mutable copy, writes the whole step.
- (BOOL)editStep:(NSString *)stepID block:(void (^)(NSMutableDictionary *step))block {
  NSDictionary *current = [self step:stepID];
  if ([current count] == 0) return NO;
  NSMutableDictionary *copy = DBFMutable(current);
  block(copy);
  return [self writeStep:stepID value:copy];
}

- (NSString *)newStepIDWithPrefix:(NSString *)prefix {
  NSDictionary *steps = [self steps];
  for (int attempt = 0; attempt < 8; attempt++) {
    NSString *candidate = [prefix stringByAppendingString:DBFRandomHex(3)];
    if ([steps objectForKey:candidate] == nil) return candidate;
  }
  return [prefix stringByAppendingString:DBFRandomHex(8)];
}

// The built-in string in every language the household offers.
- (NSDictionary *)textMapForKey:(NSString *)key {
  NSMutableDictionary *map = [NSMutableDictionary dictionary];
  for (NSString *lang in [self languages]) {
    NSString *text = [DBGeneratedStringsForLanguage(lang) objectForKey:key];
    if ([text length] == 0) text = [DBGeneratedStringsForLanguage(@"en") objectForKey:key];
    if ([text length] > 0) [map setObject:text forKey:lang];
  }
  return map;
}

#pragma mark - field helpers

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

- (DBEditField *)danger:(NSString *)title message:(NSString *)message block:(void (^)(void))block {
  DBEditField *field = [self action:title block:block];
  field.destructive = YES;
  field.confirmMessage = message;
  return field;
}

- (DBEditField *)toggle:(NSString *)title value:(BOOL)value change:(BOOL (^)(BOOL))change {
  DBEditField *field = [DBEditField kind:DBEditKindBool title:title
                                   value:[NSNumber numberWithBool:value]];
  field.onChange = ^BOOL(id raw) { return change([raw boolValue]); };
  return field;
}

- (DBEditField *)choice:(NSString *)title value:(NSString *)value choices:(NSArray *)choices
                 change:(BOOL (^)(NSString *))change {
  DBEditField *field = [DBEditField kind:DBEditKindChoice title:title value:value ?: @""];
  field.choices = choices;
  field.onChange = ^BOOL(id raw) { return change(DBFString(raw)); };
  return field;
}

// One text row per language for the members of a text map.
- (NSArray *)textFields:(NSDictionary *)map limit:(NSUInteger)limit
                  place:(NSString *)placeholder
                    set:(BOOL (^)(NSString *lang, NSString *text))set {
  NSMutableArray *fields = [NSMutableArray array];
  for (NSString *lang in [self languages]) {
    NSString *current = DBFString([map objectForKey:lang]);
    DBEditField *field = [DBEditField kind:DBEditKindText title:[DBTexts langDisplayName:lang]
                                     value:current];
    field.placeholder = placeholder;
    field.onChange = ^BOOL(id raw) {
      NSString *text = DBFTrim(DBFString(raw));
      if ([text length] > limit) {
        [_editor showMessage:[self t:@"visitor_flow.bad_text"]];
        return NO;
      }
      return set(lang, text);
    };
    [fields addObject:field];
  }
  return fields;
}

// Sets or clears one language of a text member of a step. An emptied map is removed, because
// title and body are optional.
- (BOOL)setText:(NSString *)text lang:(NSString *)lang member:(NSString *)member
           step:(NSString *)stepID option:(NSString *)optionID {
  return [self editStep:stepID block:^(NSMutableDictionary *step) {
    NSMutableDictionary *holder = step;
    if (optionID != nil) {
      holder = nil;
      for (NSMutableDictionary *option in DBFArray([step objectForKey:@"options"]))
        if ([DBFString([option objectForKey:@"id"]) isEqualToString:optionID]) holder = option;
      if (holder == nil) return;
    }
    NSMutableDictionary *map = DBFMutable(DBFDict([holder objectForKey:member]));
    if ([text length] == 0) [map removeObjectForKey:lang]; else [map setObject:text forKey:lang];
    if ([map count] == 0) [holder removeObjectForKey:member]; else [holder setObject:map forKey:member];
  }];
}

#pragma mark - root page

- (DBEditPage *)rootPage {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[self t:@"flow_editor.title"] build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSDictionary *flow = [pages flow];
    NSDictionary *steps = [pages steps];
    BOOL hasSteps = [steps count] > 0;
    NSMutableArray *sections = [NSMutableArray array];

    DBEditField *enabled = [pages toggle:[pages t:@"flow_editor.enabled"]
        value:![[flow objectForKey:@"enabled"] isEqual:@NO]
        change:^BOOL(BOOL on) { return [weakSelf setLeaf:@"enabled" value:[NSNumber numberWithBool:on]]; }];
    DBEditSection *top = [DBEditSection title:nil fields:@[ enabled ]];
    top.footer = [pages t:@"flow_editor.enabled_hint"];
    [sections addObject:top];

    if (!hasSteps) {
      DBEditField *note = [DBEditField kind:DBEditKindInfo title:[pages t:@"flow_editor.default_note"]
                                      value:@""];
      DBEditField *customize = [pages action:[pages t:@"flow_editor.customize"] block:^{
        [weakSelf applyTemplate:@"default" replacing:NO];
      }];
      [sections addObject:[DBEditSection title:nil fields:@[ note, customize ]]];
    } else {
      [sections addObject:[pages settingsSection]];
      [sections addObject:[pages startSection]];
      [sections addObjectsFromArray:[pages stepsSections]];
    }

    if ([pages canTry]) {
      DBEditField *tryIt = [pages page:[pages t:@"flow_editor.preview"] detail:nil
                                 build:^DBEditPage *{ return [weakSelf previewPage]; }];
      [sections addObject:[DBEditSection title:nil fields:@[ tryIt ]]];
    }

    NSMutableArray *templates = [NSMutableArray array];
    for (NSArray *entry in @[ @[ @"default", @"flow_editor.template_default" ],
                              @[ @"purposes", @"flow_editor.template_purposes" ],
                              @[ @"delivery", @"flow_editor.template_delivery" ] ]) {
      NSString *name = [entry objectAtIndex:0];
      DBEditField *row = [pages action:[pages t:[entry objectAtIndex:1]] block:^{
        [weakSelf applyTemplate:name replacing:YES];
      }];
      if (hasSteps) {
        row.confirm = YES;
        row.confirmMessage = [pages t:@"flow_editor.template_confirm"];
      }
      [templates addObject:row];
    }
    [sections addObject:[DBEditSection title:[pages t:@"flow_editor.templates"] fields:templates]];

    if ([flow count] > 0) {
      DBEditField *reset = [pages danger:[pages t:@"flow_editor.reset_default"]
                                 message:[pages t:@"flow_editor.reset_default_confirm"] block:^{
        if ([weakSelf commit:@[ [weakSelf deleteOp:@"visitor_flow"] ]]) [editor reloadPage];
      }];
      [sections addObject:[DBEditSection title:nil fields:@[ reset ]]];
    }
    return sections;
  }];
  page.onAdd = ^{
    DBFlowEditorPages *pages = weakSelf;
    if ([[pages steps] count] == 0) {
      [editor showMessage:[pages t:@"flow_editor.default_note"]];
      return;
    }
    [editor pushPage:[pages addStepPage]];
  };
  return page;
}

- (DBEditSection *)settingsSection {
  __weak DBFlowEditorPages *weakSelf = self;
  NSDictionary *flow = [self flow];
  BOOL requireCall = ![[flow objectForKey:@"require_call"] isEqual:@NO];
  DBEditField *require = [self toggle:[self t:@"flow_editor.require_call"] value:requireCall
      change:^BOOL(BOOL on) {
        return [weakSelf setLeaf:@"require_call" value:[NSNumber numberWithBool:on]];
      }];
  id idleValue = [flow objectForKey:@"idle_s"];
  DBEditField *idle = [DBEditField kind:DBEditKindNumber title:[self t:@"flow_editor.idle_s"]
      value:[NSNumber numberWithInteger:[idleValue isKindOfClass:[NSNumber class]]
                                            ? [idleValue integerValue] : 45]];
  idle.minimum = 15;
  idle.maximum = 300;
  idle.onChange = ^BOOL(id value) { return [weakSelf setLeaf:@"idle_s" value:value]; };
  DBEditSection *section = [DBEditSection title:nil fields:@[ require, idle ]];
  section.footer = requireCall ? nil : [self t:@"flow_editor.require_call_off_warning"];
  return section;
}

- (DBEditSection *)startSection {
  __weak DBFlowEditorPages *weakSelf = self;
  NSArray *pages = [self stepChoicesOfKind:@"page"];
  NSString *start = DBFString([[self flow] objectForKey:@"start"]);
  NSMutableArray *fields = [NSMutableArray array];
  [fields addObject:[self choice:[self t:@"flow_editor.start"] value:start choices:pages
      change:^BOOL(NSString *value) { return [weakSelf setLeaf:@"start" value:value]; }]];
  NSDictionary *doors = DBFDict([[self cfg] objectForKey:@"doors"]);
  for (NSString *door in [DBConfigUtil sortedByOrder:doors]) {
    NSString *key = [NSString stringWithFormat:@"doors.%@.visitor_flow.start", door];
    NSString *current = DBFString([DBConfigUtil str:[self cfg] path:key]);
    NSMutableArray *choices = [NSMutableArray arrayWithObject:
        @[ @"", [self t:@"flow_editor.door_start_inherit"] ]];
    [choices addObjectsFromArray:pages];
    NSString *name = [DBConfigUtil labelOf:DBFDict([doors objectForKey:door]) lang:[self lang]
                                  fallback:door];
    [fields addObject:[self choice:[NSString stringWithFormat:@"%@: %@",
                                       [self t:@"flow_editor.door_start"], name]
                             value:current choices:choices
        change:^BOOL(NSString *value) {
          return [value length] == 0 ? [weakSelf commit:@[ [weakSelf deleteOp:key] ]]
                                     : [weakSelf commit:@[ [weakSelf setOp:key value:value] ]];
        }]];
  }
  return [DBEditSection title:nil fields:fields];
}

- (NSArray *)stepsSections {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSArray *ids = [self orderedStepIDs];
  NSMutableArray *fields = [NSMutableArray array];
  for (NSString *stepID in ids) {
    [fields addObject:[self page:[self stepName:stepID] detail:nil
                           build:^DBEditPage *{ return [weakSelf stepPage:stepID]; }]];
  }
  DBEditSection *section = [DBEditSection title:[self t:@"flow_editor.steps"] fields:fields];
  section.footer = [self t:@"flow_editor.steps_hint"];
  section.onDelete = ^BOOL(NSInteger index) {
    NSArray *now = [weakSelf orderedStepIDs];
    if (index < 0 || index >= (NSInteger)[now count]) return NO;
    return [weakSelf deleteStep:[now objectAtIndex:(NSUInteger)index] editor:editor];
  };
  // The stock reorder control: the new sequence is stored as consecutive `order` values, every
  // changed step rewritten whole in one batch.
  section.onMove = ^BOOL(NSInteger from, NSInteger to) {
    NSArray *sequence = [DBFlowOrder sequence:[weakSelf orderedStepIDs] movingFrom:from to:to];
    NSMutableArray *ops = [NSMutableArray array];
    for (NSDictionary *write in [DBFlowOrder writesForSequence:sequence steps:[weakSelf steps]])
      [ops addObject:[weakSelf setOp:[@"visitor_flow.steps."
                                         stringByAppendingString:[write objectForKey:@"id"]]
                               value:[write objectForKey:@"step"]]];
    return [weakSelf commit:ops];
  };
  DBEditField *add = [self action:[self t:@"flow_editor.add_step"] block:^{
    [editor pushPage:[weakSelf addStepPage]];
  }];
  return @[ section, [DBEditSection title:nil fields:@[ add ]] ];
}

// A step that others lead to, or the start page, stays until they are changed.
- (BOOL)deleteStep:(NSString *)stepID editor:(DBEditorView *)editor {
  NSMutableArray *blockers = [NSMutableArray arrayWithArray:[self stepsReferencing:stepID]];
  if ([DBFString([[self flow] objectForKey:@"start"]) isEqualToString:stepID])
    [blockers insertObject:[self t:@"flow_editor.start"] atIndex:0];
  NSDictionary *doors = DBFDict([[self cfg] objectForKey:@"doors"]);
  for (NSString *door in doors)
    if ([DBFString([DBConfigUtil str:[self cfg]
            path:[NSString stringWithFormat:@"doors.%@.visitor_flow.start", door]]) isEqualToString:stepID])
      [blockers addObject:[self t:@"flow_editor.door_start"]];
  if ([blockers count] > 0) {
    [editor showMessage:[_texts t:@"flow_editor.step_in_use",
                         [blockers componentsJoinedByString:@", "], nil]];
    return NO;
  }
  return [self commit:@[ [self deleteOp:[@"visitor_flow.steps." stringByAppendingString:stepID]] ]];
}

#pragma mark - templates

// The template comes from Core; it is written as ordinary steps. When it replaces a flow, the
// steps that go away are deleted in the same batch, and door starts that would dangle are cleared.
- (void)applyTemplate:(NSString *)name replacing:(BOOL)replacing {
  NSDictionary *result = [_core visitorFlowTemplateJson:name];
  NSDictionary *template = DBFDict([result objectForKey:@"flow"]);
  NSDictionary *templateSteps = DBFDict([template objectForKey:@"steps"]);
  if (![[result objectForKey:@"ok"] boolValue] || [templateSteps count] == 0) {
    [_editor showMessage:[self t:[DBCoreBridge supportsVisitorFlow] ? @"settings.save_failed"
                                                                    : @"editor.core_too_old"]];
    return;
  }
  NSMutableArray *ops = [NSMutableArray array];
  for (NSString *member in @[ @"enabled", @"start", @"idle_s", @"require_call" ])
    if ([template objectForKey:member] != nil)
      [ops addObject:[self setOp:[@"visitor_flow." stringByAppendingString:member]
                           value:[template objectForKey:member]]];
  if (replacing)
    for (NSString *old in [self steps])
      if ([templateSteps objectForKey:old] == nil)
        [ops addObject:[self deleteOp:[@"visitor_flow.steps." stringByAppendingString:old]]];
  for (NSString *stepID in [[templateSteps allKeys] sortedArrayUsingSelector:@selector(compare:)])
    [ops addObject:[self setOp:[@"visitor_flow.steps." stringByAppendingString:stepID]
                         value:[templateSteps objectForKey:stepID]]];
  NSDictionary *doors = DBFDict([[self cfg] objectForKey:@"doors"]);
  for (NSString *door in doors) {
    NSString *key = [NSString stringWithFormat:@"doors.%@.visitor_flow.start", door];
    NSString *current = DBFString([DBConfigUtil str:[self cfg] path:key]);
    if ([current length] > 0 &&
        ![[DBFDict([templateSteps objectForKey:current]) objectForKey:@"kind"] isEqual:@"page"])
      [ops addObject:[self deleteOp:key]];
  }
  if ([self commit:ops]) [_editor reloadPage];
}

#pragma mark - add a step

- (DBEditPage *)addStepPage {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:[self t:@"flow_editor.add_step"] build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *kind in @[ @"page", @"call", @"notify", @"end" ]) {
      [fields addObject:[pages action:[pages kindLabel:kind] block:^{
        NSString *created = [weakSelf createStepOfKind:kind];
        if (created == nil) return;
        [editor popPage];
        [editor reloadPage];
        [editor pushPage:[weakSelf stepPage:created]];
      }]];
    }
    return @[ [DBEditSection title:nil fields:fields] ];
  }];
}

// A new step arrives with whatever it needs to be valid: a page with one option leading to a
// call, a notify with its closing page. The helpers are reused when they already exist.
- (NSString *)createStepOfKind:(NSString *)kind {
  if ([[self steps] count] >= 32) {
    [_editor showMessage:[self t:@"visitor_flow.too_many_steps"]];
    return nil;
  }
  NSString *prefix = [kind isEqualToString:@"page"] ? @"s_" : [kind isEqualToString:@"call"] ? @"c_"
      : [kind isEqualToString:@"notify"] ? @"n_" : @"e_";
  NSString *stepID = [self newStepIDWithPrefix:prefix];
  NSMutableDictionary *created = [NSMutableDictionary dictionary];
  NSMutableArray *ids = [NSMutableArray arrayWithObject:stepID];
  NSDictionary *thanks = @{ @"kind" : @"end", @"title" : [self textMapForKey:@"core.flow.thanks_title"],
                            @"return_s" : @8 };
  if ([kind isEqualToString:@"end"]) {
    [created setObject:thanks forKey:stepID];
  } else if ([kind isEqualToString:@"call"]) {
    [created setObject:@{ @"kind" : @"call" } forKey:stepID];
  } else if ([kind isEqualToString:@"notify"]) {
    NSString *end = [[[self stepChoicesOfKind:@"end"] firstObject] firstObject];
    if (end == nil) {
      end = [self newStepIDWithPrefix:@"e_"];
      [created setObject:thanks forKey:end];
      [ids addObject:end];
    }
    [created setObject:@{ @"kind" : @"notify", @"message" : [self textMapForKey:@"core.flow.left_message"],
                          @"to" : end } forKey:stepID];
  } else {
    NSString *call = [[[self stepChoicesOfKind:@"call"] firstObject] firstObject];
    if (call == nil) {
      call = [self newStepIDWithPrefix:@"c_"];
      [created setObject:@{ @"kind" : @"call" } forKey:call];
      [ids addObject:call];
    }
    NSDictionary *option = @{ @"id" : @"o_1", @"label" : [self textMapForKey:@"core.flow.call"],
                              @"style" : @"primary", @"to" : call };
    [created setObject:@{ @"kind" : @"page", @"title" : [self textMapForKey:@"core.flow.home_title"],
                          @"options" : @[ option ] } forKey:stepID];
  }
  return [self commit:[self opsForNewSteps:created ids:ids after:nil]] ? stepID : nil;
}

#pragma mark - try it

// Walks the stored flow with the same model the door screen uses. Every edit is stored at once, so
// the stored flow is the draft. A tap shows the Core call it would make and makes none.
- (BOOL)canTry {
  return _preview == nil && [DBCoreBridge supportsVisitorFlow];
}

- (void)setSimLanguage:(NSString *)lang {
  _simLang = [lang copy];
  _sim.lang = lang;
}

- (void)restartAndReload {
  [self restartSim];
  [_editor reloadPage];
}

- (void)restartSim {
  NSDictionary *document = [_core visitorFlowJson:_boot.door ?: @""];
  _simResult = nil;
  if (![document isKindOfClass:[NSDictionary class]]) {
    _sim = nil;
    return;
  }
  if ([_simLang length] == 0)
    _simLang = [[self languages] containsObject:[self lang]] ? [self lang]
                                                              : [[self languages] firstObject];
  _sim = [[DBVisitorFlowModel alloc] initWithFlow:document lang:_simLang];
}

- (DBEditPage *)previewPage {
  return [self previewPageAfterTaps:nil];
}

- (DBEditPage *)previewPageAfterTaps:(NSArray *)optionIDs {
  __weak DBFlowEditorPages *weakSelf = self;
  [self restartSim];
  for (NSString *optionID in optionIDs) [self simTap:optionID];
  return [DBEditPage title:[self t:@"flow_editor.preview"] build:^NSArray *{ return [weakSelf simSections]; }];
}

- (DBEditField *)simInfo:(NSString *)title detail:(NSString *)detail {
  DBEditField *field = [DBEditField kind:DBEditKindInfo title:title value:detail ?: @""];
  field.detail = detail;
  return field;
}

- (void)simTap:(NSString *)optionID {
  NSDictionary *plan = [_sim planForTap:optionID];
  if (plan == nil) return;
  NSString *action = DBFString([plan objectForKey:@"action"]);
  _simResult = nil;
  if ([action isEqualToString:@"press"]) {
    NSString *purpose = DBFString([plan objectForKey:@"purpose"]);
    _simResult = [purpose length] > 0
        ? [_texts t:@"flow_editor.sim_ring", [self purposeLabel:purpose], nil]
        : [self t:@"flow_editor.sim_ring_any"];
  } else if ([action isEqualToString:@"notify"]) {
    NSDictionary *step = DBFDict([DBFDict([_sim.flow objectForKey:@"steps"])
                                     objectForKey:DBFString([plan objectForKey:@"step"])]);
    _simResult = [_texts t:@"flow_editor.sim_message", [_sim text:[step objectForKey:@"message"]], nil];
  }
  [_sim applyEvent:@{ @"tap" : optionID }];
  [_editor reloadPage];
}

- (void)simEvent:(NSDictionary *)event {
  _simResult = nil;
  [_sim applyEvent:event];
  [_editor reloadPage];
}

- (NSArray *)simSections {
  __weak DBFlowEditorPages *weakSelf = self;
  NSMutableArray *sections = [NSMutableArray array];
  NSMutableArray *languages = [NSMutableArray array];
  for (NSString *lang in [self languages]) [languages addObject:@[ lang, [DBTexts langDisplayName:lang] ]];
  DBEditField *language = [self choice:[self t:@"flow_editor.sim_language"] value:_simLang
      choices:languages change:^BOOL(NSString *value) {
    [weakSelf setSimLanguage:value];
    return YES;
  }];
  DBEditSection *top = [DBEditSection title:nil fields:@[ language ]];
  top.footer = [self t:@"flow_editor.sim_hint"];
  [sections addObject:top];
  if (_sim == nil) {
    [sections addObject:[DBEditSection title:nil fields:@[
        [self simInfo:[self t:@"editor.core_too_old"] detail:nil] ]]];
    return sections;
  }
  if (!_sim.active) {
    [sections addObject:[DBEditSection title:nil fields:@[
        [self simInfo:[self t:@"flow_editor.sim_classic"] detail:nil] ]]];
    return sections;
  }
  if ([_simResult length] > 0)
    [sections addObject:[DBEditSection title:nil fields:@[ [self simInfo:_simResult detail:nil] ]]];

  NSString *mode = _sim.mode;
  NSDictionary *step = [_sim currentStep];
  NSString *title = [_sim text:[step objectForKey:@"title"]];
  NSString *body = [_sim text:[step objectForKey:@"body"]];
  if ([title length] > 0 || [body length] > 0)
    [sections addObject:[DBEditSection title:nil fields:@[
        [self simInfo:[title length] > 0 ? title : body detail:[title length] > 0 ? body : nil] ]]];
  NSMutableArray *rows = [NSMutableArray array];
  if ([mode isEqualToString:DBVisitorFlowModePage]) {
    for (NSDictionary *option in [_sim currentOptions]) {
      NSString *optionID = DBFString([option objectForKey:@"id"]);
      DBEditField *row = [self action:DBFString([option objectForKey:@"label"]) block:^{
        [weakSelf simTap:optionID];
      }];
      NSString *name = [DBPurposeModel iconNameForOptionPurpose:DBFString([option objectForKey:@"purpose"])
                                                           icon:DBFString([option objectForKey:@"icon"])];
      if (name != nil)
        row.image = [DBIconAsset tintedImageNamed:name color:[UIColor darkGrayColor]
                                             size:CGSizeMake(24, 24)];
      [rows addObject:row];
    }
    if ([_sim canGoBack])
      [rows addObject:[self action:[self t:@"flow.back"] block:^{ [weakSelf simEvent:@{ @"back" : @YES }]; }]];
  } else if ([mode isEqualToString:DBVisitorFlowModeEnd]) {
    [rows addObject:[self action:[self t:@"flow.done"] block:^{ [weakSelf simEvent:@{ @"done" : @YES }]; }]];
  }
  if ([rows count] > 0) [sections addObject:[DBEditSection title:nil fields:rows]];

  DBEditField *restart = [self action:[self t:@"flow_editor.sim_restart"] block:^{
    [weakSelf restartAndReload];
  }];
  DBEditField *idle = [self action:[self t:@"flow_editor.sim_idle"] block:^{
    [weakSelf simEvent:@{ @"idle_timeout" : @YES }];
  }];
  [sections addObject:[DBEditSection title:nil fields:@[ restart, idle ]]];
  return sections;
}

#pragma mark - step page

- (DBEditPage *)stepPage:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:[self stepName:stepID] build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSDictionary *step = [pages step:stepID];
    NSString *kind = DBFString([step objectForKey:@"kind"]);
    NSMutableArray *sections = [NSMutableArray array];
    if ([step count] == 0) return sections;

    DBEditField *kindRow = [DBEditField kind:DBEditKindInfo title:[pages t:@"flow_editor.field_kind"]
                                       value:[pages kindLabel:kind]];
    DBEditField *idRow = [DBEditField kind:DBEditKindInfo title:[pages t:@"flow_editor.field_id"]
                                     value:stepID];
    DBEditSection *identity = [DBEditSection title:nil fields:@[ kindRow, idRow ]];
    identity.footer = [pages t:@"flow_editor.kind_fixed_hint"];
    [sections addObject:identity];

    if ([kind isEqualToString:@"page"] || [kind isEqualToString:@"end"]) {
      [sections addObject:[DBEditSection title:[pages t:@"flow_editor.field_title"]
          fields:[pages textFields:DBFDict([step objectForKey:@"title"]) limit:kTitleLimit place:nil
                               set:^BOOL(NSString *lang, NSString *text) {
        return [weakSelf setText:text lang:lang member:@"title" step:stepID option:nil];
      }]]];
      DBEditField *body = [pages page:[pages t:@"flow_editor.field_body"]
          detail:[pages bodySummary:DBFDict([step objectForKey:@"body"])]
           build:^DBEditPage *{ return [weakSelf bodyLanguagesPage:stepID]; }];
      DBEditSection *bodySection = [DBEditSection title:nil fields:@[ body ]];
      [sections addObject:bodySection];
      [sections addObjectsFromArray:[pages imagesSections:stepID]];
    }
    if ([kind isEqualToString:@"page"]) [sections addObjectsFromArray:[pages optionsSections:stepID]];
    if ([kind isEqualToString:@"call"]) [sections addObject:[pages callSection:stepID]];
    if ([kind isEqualToString:@"notify"]) {
      [sections addObject:[DBEditSection title:[pages t:@"flow_editor.field_message"]
          fields:[pages textFields:DBFDict([step objectForKey:@"message"]) limit:kMessageLimit
                             place:nil
                               set:^BOOL(NSString *lang, NSString *text) {
        return [weakSelf setText:text lang:lang member:@"message" step:stepID option:nil];
      }]]];
      [sections addObject:[pages notifySection:stepID]];
    }
    if ([kind isEqualToString:@"end"]) {
      id returnS = [step objectForKey:@"return_s"];
      DBEditField *seconds = [DBEditField kind:DBEditKindNumber
          title:[pages t:@"flow_editor.field_return_s"]
          value:[NSNumber numberWithInteger:[returnS isKindOfClass:[NSNumber class]]
                                                ? [returnS integerValue] : 8]];
      seconds.minimum = 3;
      seconds.maximum = 60;
      seconds.onChange = ^BOOL(id value) {
        return [weakSelf editStep:stepID block:^(NSMutableDictionary *copy) {
          [copy setObject:value forKey:@"return_s"];
        }];
      };
      [sections addObject:[DBEditSection title:nil fields:@[ seconds ]]];
    }

    DBEditField *duplicate = [pages action:[pages t:@"flow_editor.duplicate_step"] block:^{
      DBFlowEditorPages *inner = weakSelf;
      if ([[inner steps] count] >= 32) {
        [editor showMessage:[inner t:@"visitor_flow.too_many_steps"]];
        return;
      }
      NSString *prefix = [stepID length] > 2 && [stepID characterAtIndex:1] == '_'
          ? [stepID substringToIndex:2] : @"s_";
      NSString *copyID = [inner newStepIDWithPrefix:prefix];
      if ([inner commit:[inner opsForNewSteps:@{ copyID : [inner step:stepID] } ids:@[ copyID ]
                                        after:stepID]]) {
        [editor popPage];
        [editor reloadPage];
        [editor pushPage:[inner stepPage:copyID]];
      }
    }];
    DBEditField *remove = [pages danger:[pages t:@"flow_editor.delete_step"]
                                message:[pages t:@"editor.delete_confirm"] block:^{
      DBFlowEditorPages *inner = weakSelf;
      if ([inner deleteStep:stepID editor:editor]) [editor popPage];
    }];
    [sections addObject:[DBEditSection title:nil fields:@[ duplicate, remove ]]];
    return sections;
  }];
}

- (NSString *)bodySummary:(NSDictionary *)body {
  NSString *text = [self text:body];
  return [text length] > 24 ? [[text substringToIndex:24] stringByAppendingString:@"…"] : text;
}

#pragma mark - body text

// The body is plain text; one paragraph per row keeps every paragraph a single-line entry. A typed
// "\n" inside a paragraph is a line break.
- (DBEditPage *)bodyLanguagesPage:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  return [DBEditPage title:[self t:@"flow_editor.field_body"] build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSDictionary *body = DBFDict([[pages step:stepID] objectForKey:@"body"]);
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *lang in [pages languages]) {
      NSString *text = DBFString([body objectForKey:lang]);
      [fields addObject:[pages page:[DBTexts langDisplayName:lang] detail:[pages bodySummary:@{ lang : text }]
                              build:^DBEditPage *{ return [weakSelf bodyPage:stepID lang:lang]; }]];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"flow_editor.body_hint"];
    return @[ section ];
  }];
}

- (NSArray *)paragraphsOf:(NSString *)text {
  if ([text length] == 0) return @[];
  return [text componentsSeparatedByString:@"\n\n"];
}

- (BOOL)writeParagraphs:(NSArray *)paragraphs step:(NSString *)stepID lang:(NSString *)lang {
  NSMutableArray *kept = [NSMutableArray array];
  for (NSString *paragraph in paragraphs)
    if ([DBFTrim(paragraph) length] > 0) [kept addObject:paragraph];
  NSString *text = [kept componentsJoinedByString:@"\n\n"];
  if ([text length] > kBodyLimit || [kept count] > 8) {
    [_editor showMessage:[self t:@"visitor_flow.bad_text"]];
    return NO;
  }
  return [self setText:text lang:lang member:@"body" step:stepID option:nil];
}

- (DBEditPage *)bodyPage:(NSString *)stepID lang:(NSString *)lang {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  DBEditPage *page = [DBEditPage title:[DBTexts langDisplayName:lang] build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSDictionary *body = DBFDict([[pages step:stepID] objectForKey:@"body"]);
    NSArray *paragraphs = [pages paragraphsOf:DBFString([body objectForKey:lang])];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < [paragraphs count]; i++) {
      NSString *shown = [[paragraphs objectAtIndex:i] stringByReplacingOccurrencesOfString:@"\n"
                                                                                withString:@"\\n"];
      DBEditField *field = [DBEditField kind:DBEditKindText
          title:[NSString stringWithFormat:@"%@ %lu", [pages t:@"flow_editor.paragraph"],
                                           (unsigned long)(i + 1)] value:shown];
      field.detail = shown;
      field.onChange = ^BOOL(id raw) {
        NSMutableArray *next = [NSMutableArray arrayWithArray:
            [weakSelf paragraphsOf:DBFString([DBFDict([[weakSelf step:stepID] objectForKey:@"body"])
                                                  objectForKey:lang])]];
        if (i >= [next count]) return NO;
        [next replaceObjectAtIndex:i withObject:[DBFString(raw)
            stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"]];
        return [weakSelf writeParagraphs:next step:stepID lang:lang];
      };
      [fields addObject:field];
    }
    DBEditSection *section = [DBEditSection title:nil fields:fields];
    section.footer = [pages t:@"flow_editor.body_hint"];
    section.onDelete = ^BOOL(NSInteger index) {
      NSMutableArray *next = [NSMutableArray arrayWithArray:
          [weakSelf paragraphsOf:DBFString([DBFDict([[weakSelf step:stepID] objectForKey:@"body"])
                                                objectForKey:lang])]];
      if (index < 0 || index >= (NSInteger)[next count]) return NO;
      [next removeObjectAtIndex:(NSUInteger)index];
      return [weakSelf writeParagraphs:next step:stepID lang:lang];
    };
    section.onMove = ^BOOL(NSInteger from, NSInteger to) {
      NSMutableArray *next = [NSMutableArray arrayWithArray:
          [weakSelf paragraphsOf:DBFString([DBFDict([[weakSelf step:stepID] objectForKey:@"body"])
                                                objectForKey:lang])]];
      if (from < 0 || to < 0 || from >= (NSInteger)[next count] || to >= (NSInteger)[next count])
        return NO;
      id moved = [next objectAtIndex:(NSUInteger)from];
      [next removeObjectAtIndex:(NSUInteger)from];
      [next insertObject:moved atIndex:(NSUInteger)to];
      return [weakSelf writeParagraphs:next step:stepID lang:lang];
    };
    return @[ section ];
  }];
  page.onAdd = ^{
    DBFlowEditorPages *pages = weakSelf;
    [editor promptTitle:[pages t:@"flow_editor.paragraph_add"] value:@"" placeholder:nil
               keyboard:UIKeyboardTypeDefault secure:NO then:^(NSString *text) {
      DBFlowEditorPages *inner = weakSelf;
      NSString *paragraph = [DBFTrim(text) stringByReplacingOccurrencesOfString:@"\\n"
                                                                     withString:@"\n"];
      if (!inner || [paragraph length] == 0) return;
      NSMutableArray *next = [NSMutableArray arrayWithArray:
          [inner paragraphsOf:DBFString([DBFDict([[inner step:stepID] objectForKey:@"body"])
                                             objectForKey:lang])]];
      [next addObject:paragraph];
      if ([inner writeParagraphs:next step:stepID lang:lang]) [editor reloadPage];
    }];
  };
  return page;
}

#pragma mark - images

- (NSArray *)imagesSections:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSArray *images = DBFArray([[self step:stepID] objectForKey:@"images"]);
  NSMutableArray *fields = [NSMutableArray array];
  for (NSUInteger i = 0; i < [images count]; i++) {
    NSDictionary *image = DBFDict([images objectAtIndex:i]);
    NSString *asset = DBFString([image objectForKey:@"asset"]);
    NSString *place = [DBFString([image objectForKey:@"place"]) isEqualToString:@"below"]
        ? [self t:@"flow_editor.image_below"] : [self t:@"flow_editor.image_above"];
    [fields addObject:[self page:[self assetLabel:asset] detail:place
                           build:^DBEditPage *{ return [weakSelf imagePage:stepID index:i]; }]];
  }
  DBEditSection *section = [DBEditSection title:[self t:@"flow_editor.field_images"] fields:fields];
  section.onDelete = ^BOOL(NSInteger index) {
    return [weakSelf editStep:stepID block:^(NSMutableDictionary *step) {
      NSMutableArray *list = [step objectForKey:@"images"];
      if (index < 0 || index >= (NSInteger)[list count]) return;
      [list removeObjectAtIndex:(NSUInteger)index];
      if ([list count] == 0) [step removeObjectForKey:@"images"];
    }];
  };
  DBEditField *add = [self action:[self t:@"flow_editor.add_image"] block:^{
    DBFlowEditorPages *pages = weakSelf;
    if ([DBFArray([[pages step:stepID] objectForKey:@"images"]) count] >= 2) {
      [editor showMessage:[pages t:@"flow_editor.max_images"]];
      return;
    }
    [editor pushPage:[pages addImagePage:stepID]];
  }];
  return @[ section, [DBEditSection title:nil fields:@[ add ]] ];
}

- (NSString *)assetLabel:(NSString *)hash {
  NSDictionary *asset = DBFDict([DBConfigUtil dig:[self cfg]
      path:[@"assets." stringByAppendingString:hash ?: @""]]);
  NSString *label = DBFString([asset objectForKey:@"label"]);
  if ([label length] > 0) return label;
  return [hash length] >= 8 ? [hash substringToIndex:8] : (hash ?: @"");
}

- (BOOL)attachImage:(NSString *)hash toStep:(NSString *)stepID {
  NSString *label = [self assetLabel:hash];
  return [self editStep:stepID block:^(NSMutableDictionary *step) {
    NSMutableArray *list = [step objectForKey:@"images"];
    if (list == nil) {
      list = [NSMutableArray array];
      [step setObject:list forKey:@"images"];
    }
    if ([list count] >= 2) return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        hash, @"asset", @"above", @"place", nil];
    if ([label length] > 0 && [label length] <= kAltLimit)
      [entry setObject:@{ [self lang] : label } forKey:@"alt"];
    [list addObject:entry];
  }];
}

// Existing image assets first, then the photo library through the same upload path as the theme.
- (DBEditPage *)addImagePage:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:[self t:@"flow_editor.add_image"] build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSDictionary *assets = DBFDict([[pages cfg] objectForKey:@"assets"]);
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *hash in [[assets allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      if (![DBFString([DBFDict([assets objectForKey:hash]) objectForKey:@"type"]) hasPrefix:@"image/"])
        continue;
      [rows addObject:[pages action:[pages assetLabel:hash] block:^{
        if ([weakSelf attachImage:hash toStep:stepID]) {
          [editor popPage];
          [editor reloadPage];
        }
      }]];
    }
    DBEditSection *library = [DBEditSection title:[pages t:@"editor.images"] fields:rows];
    if ([rows count] == 0) library.footer = [pages t:@"flow_editor.no_images"];
    DBEditField *choose = [pages action:[pages t:@"editor.choose_photo"] block:^{
      [weakSelf pickPhotoThen:^(NSString *hash) {
        if ([weakSelf attachImage:hash toStep:stepID]) {
          [editor popPage];
          [editor reloadPage];
        }
      }];
    }];
    return @[ [DBEditSection title:nil fields:@[ choose ]], library ];
  }];
}

- (DBEditPage *)imagePage:(NSString *)stepID index:(NSUInteger)index {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:[self t:@"flow_editor.field_images"] build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSArray *images = DBFArray([[pages step:stepID] objectForKey:@"images"]);
    if (index >= [images count]) return @[];
    NSDictionary *image = DBFDict([images objectAtIndex:index]);
    DBEditField *asset = [DBEditField kind:DBEditKindInfo title:[pages t:@"editor.images"]
        value:[pages assetLabel:DBFString([image objectForKey:@"asset"])]];
    DBEditSection *alt = [DBEditSection title:[pages t:@"flow_editor.image_alt"]
        fields:[pages textFields:DBFDict([image objectForKey:@"alt"]) limit:kAltLimit place:nil
                             set:^BOOL(NSString *lang, NSString *text) {
      return [weakSelf editStep:stepID block:^(NSMutableDictionary *step) {
        NSMutableArray *list = [step objectForKey:@"images"];
        if (index >= [list count]) return;
        NSMutableDictionary *entry = [list objectAtIndex:index];
        NSMutableDictionary *map = DBFMutable(DBFDict([entry objectForKey:@"alt"]));
        if ([text length] == 0) [map removeObjectForKey:lang]; else [map setObject:text forKey:lang];
        if ([map count] == 0) [entry removeObjectForKey:@"alt"]; else [entry setObject:map forKey:@"alt"];
      }];
    }]];
    NSString *place = [DBFString([image objectForKey:@"place"]) isEqualToString:@"below"] ? @"below"
                                                                                       : @"above";
    DBEditField *placement = [pages choice:[pages t:@"flow_editor.image_place"] value:place
        choices:@[ @[ @"above", [pages t:@"flow_editor.image_above"] ],
                   @[ @"below", [pages t:@"flow_editor.image_below"] ] ]
        change:^BOOL(NSString *value) {
          return [weakSelf editStep:stepID block:^(NSMutableDictionary *step) {
            NSMutableArray *list = [step objectForKey:@"images"];
            if (index < [list count]) [[list objectAtIndex:index] setObject:value forKey:@"place"];
          }];
        }];
    DBEditField *remove = [pages danger:[pages t:@"editor.delete"]
                                message:[pages t:@"editor.delete_confirm"] block:^{
      if ([weakSelf editStep:stepID block:^(NSMutableDictionary *step) {
            NSMutableArray *list = [step objectForKey:@"images"];
            if (index >= [list count]) return;
            [list removeObjectAtIndex:index];
            if ([list count] == 0) [step removeObjectForKey:@"images"];
          }]) [editor popPage];
    }];
    return @[ [DBEditSection title:nil fields:@[ asset, placement ]], alt,
              [DBEditSection title:nil fields:@[ remove ]] ];
  }];
}

#pragma mark - photo library

// Scaled to at most 1280 px on the long edge and about 400 KB, as the contract asks.
static NSData *DBFJpegForFlow(UIImage *image) {
  CGSize size = image.size;
  CGFloat scale = MIN(1.0, 1280.0 / MAX(size.width, size.height));
  CGSize target = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
  UIGraphicsBeginImageContextWithOptions(target, YES, 1);
  [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
  UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  NSData *data = nil;
  for (CGFloat quality = 0.8; quality > 0.25; quality -= 0.1) {
    data = UIImageJPEGRepresentation(scaled, quality);
    if ([data length] <= 400 * 1024) break;
  }
  return data;
}

- (void)pickPhotoThen:(void (^)(NSString *hash))then {
  if (![DBCoreBridge supportsAssets]) {
    [_editor showMessage:[self t:@"editor.core_too_old"]];
    return;
  }
  if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPad ||
      ![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
    [_editor showMessage:[self t:@"editor.no_photos"]];
    return;
  }
  _pickerDone = [then copy];
  _picker = [[UIImagePickerController alloc] init];
  _picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
  _picker.mediaTypes = @[ @"public.image" ];
  _picker.delegate = self;
  _popover = [[UIPopoverController alloc] initWithContentViewController:_picker];
  _popover.delegate = self;
  UIView *anchor = _editor;
  CGRect rect = CGRectMake(CGRectGetMidX(anchor.bounds) - 1, 80, 2, 2);
  [_popover presentPopoverFromRect:rect inView:anchor
          permittedArrowDirections:UIPopoverArrowDirectionUp animated:YES];
}

- (void)finishPicker {
  [_popover dismissPopoverAnimated:YES];
  _popover = nil;
  _picker.delegate = nil;
  _picker = nil;
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController {
  (void)popoverController;
  _popover = nil;
  _picker.delegate = nil;
  _picker = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
  (void)picker;
  _pickerDone = nil;
  [self finishPicker];
}

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary *)info {
  (void)picker;
  UIImage *image = [info objectForKey:UIImagePickerControllerOriginalImage];
  void (^done)(NSString *) = _pickerDone;
  _pickerDone = nil;
  [self finishPicker];
  if (image == nil || done == nil) return;
  [_editor showMessage:[self t:@"editor.uploading"]];
  __weak DBFlowEditorPages *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSData *jpeg = DBFJpegForFlow(image);
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf uploadJpeg:jpeg then:done];
    });
  });
}

- (void)uploadJpeg:(NSData *)data then:(void (^)(NSString *hash))then {
  if ([data length] == 0) {
    [_editor showMessage:[self t:@"settings.save_failed"]];
    return;
  }
  NSDictionary *result = [_core addAsset:data type:@"image/jpeg" label:@"photo.jpg"];
  NSString *hash = DBFString([result objectForKey:@"hash"]);
  if (![[result objectForKey:@"ok"] boolValue] || [hash length] == 0) {
    if ([DBFString([result objectForKey:@"err"]) isEqualToString:@"admin_required"]) {
      __weak DBFlowEditorPages *weakSelf = self;
      [_router requestPinThen:^{ [weakSelf uploadJpeg:data then:then]; }];
      return;
    }
    [_editor showMessage:[NSString stringWithFormat:@"%@\n%@", [self t:@"settings.save_failed"],
                                                    DBFString([result objectForKey:@"err"])]];
    return;
  }
  then(hash);
}

#pragma mark - options

- (NSDictionary *)option:(NSString *)optionID ofStep:(NSString *)stepID {
  for (NSDictionary *option in DBFArray([[self step:stepID] objectForKey:@"options"]))
    if ([DBFString([DBFDict(option) objectForKey:@"id"]) isEqualToString:optionID]) return option;
  return @{};
}

- (NSString *)optionName:(NSDictionary *)option {
  NSString *purpose = DBFString([option objectForKey:@"purpose"]);
  NSString *label = [purpose length] > 0 ? [self purposeLabel:purpose]
                                         : [self text:[option objectForKey:@"label"]];
  return [label length] > 0 ? label : DBFString([option objectForKey:@"id"]);
}

- (NSArray *)optionsSections:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  NSArray *options = DBFArray([[self step:stepID] objectForKey:@"options"]);
  NSMutableArray *fields = [NSMutableArray array];
  for (NSDictionary *option in options) {
    NSString *optionID = DBFString([DBFDict(option) objectForKey:@"id"]);
    NSString *target = DBFString([DBFDict(option) objectForKey:@"to"]);
    BOOL primary = [[option objectForKey:@"style"] isEqual:@"primary"];
    BOOL enabled = ![[option objectForKey:@"enabled"] isEqual:@NO];
    NSString *name = [NSString stringWithFormat:@"%@%@", primary ? @"● " : @"",
                                                  [self optionName:option]];
    NSString *detail = enabled ? [self stepName:target] : [self t:@"purpose.disabled"];
    [fields addObject:[self page:name detail:detail
        build:^DBEditPage *{ return [weakSelf optionPage:optionID step:stepID]; }]];
  }
  DBEditSection *section = [DBEditSection title:[self t:@"flow_editor.field_options"] fields:fields];
  section.footer = [self t:@"editor.list_edit_hint"];
  section.onDelete = ^BOOL(NSInteger index) {
    if ([DBFArray([[weakSelf step:stepID] objectForKey:@"options"]) count] <= 1) {
      [editor showMessage:[weakSelf t:@"visitor_flow.no_options"]];
      return NO;
    }
    return [weakSelf editStep:stepID block:^(NSMutableDictionary *step) {
      NSMutableArray *list = [step objectForKey:@"options"];
      if (index >= 0 && index < (NSInteger)[list count]) [list removeObjectAtIndex:(NSUInteger)index];
    }];
  };
  section.onMove = ^BOOL(NSInteger from, NSInteger to) {
    return [weakSelf editStep:stepID block:^(NSMutableDictionary *step) {
      NSMutableArray *list = [step objectForKey:@"options"];
      if (from < 0 || to < 0 || from >= (NSInteger)[list count] || to >= (NSInteger)[list count]) return;
      id moved = [list objectAtIndex:(NSUInteger)from];
      [list removeObjectAtIndex:(NSUInteger)from];
      [list insertObject:moved atIndex:(NSUInteger)to];
    }];
  };
  DBEditField *add = [self action:[self t:@"flow_editor.add_option"] block:^{
    DBFlowEditorPages *pages = weakSelf;
    NSDictionary *step = [pages step:stepID];
    NSArray *current = DBFArray([step objectForKey:@"options"]);
    if ([current count] >= 12) {
      [editor showMessage:[pages t:@"visitor_flow.too_many_options"]];
      return;
    }
    // The new option leads to the first other step that cannot loop back: a call.
    NSString *target = [[[pages stepChoicesOfKind:@"call"] firstObject] firstObject];
    if (target == nil) {
      [editor showMessage:[pages t:@"visitor_flow.unknown_target"]];
      return;
    }
    NSString *optionID = [NSString stringWithFormat:@"o_%@", DBFRandomHex(3)];
    BOOL ok = [pages editStep:stepID block:^(NSMutableDictionary *copy) {
      NSMutableArray *list = [copy objectForKey:@"options"];
      [list addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:
          optionID, @"id", [pages textMapForKey:@"core.flow.call"], @"label", target, @"to", nil]];
    }];
    if (ok) {
      [editor reloadPage];
      [editor pushPage:[pages optionPage:optionID step:stepID]];
    }
  }];
  return @[ section, [DBEditSection title:nil fields:@[ add ]] ];
}

- (BOOL)editOption:(NSString *)optionID step:(NSString *)stepID
             block:(void (^)(NSMutableDictionary *option, NSMutableArray *siblings))block {
  return [self editStep:stepID block:^(NSMutableDictionary *step) {
    NSMutableArray *list = [step objectForKey:@"options"];
    for (NSMutableDictionary *option in list)
      if ([DBFString([option objectForKey:@"id"]) isEqualToString:optionID]) {
        block(option, list);
        return;
      }
  }];
}

- (DBEditPage *)optionPage:(NSString *)optionID step:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  __weak DBEditorView *editor = _editor;
  return [DBEditPage title:[self optionName:[self option:optionID ofStep:stepID]]
                     build:^NSArray *{
    DBFlowEditorPages *pages = weakSelf;
    NSDictionary *option = [pages option:optionID ofStep:stepID];
    if ([option count] == 0) return @[];
    NSMutableArray *sections = [NSMutableArray array];
    NSString *purpose = DBFString([option objectForKey:@"purpose"]);

    NSMutableArray *purposes = [NSMutableArray arrayWithObject:
        @[ @"", [pages t:@"flow_editor.option_purpose_none"] ]];
    NSDictionary *visit = DBFDict([[pages cfg] objectForKey:@"visit_purposes"]);
    for (NSString *identifier in [DBConfigUtil sortedByOrder:visit])
      [purposes addObject:@[ identifier, [pages purposeLabel:identifier] ]];
    DBEditField *purposeField = [pages choice:[pages t:@"flow_editor.option_purpose"] value:purpose
        choices:purposes change:^BOOL(NSString *value) {
          return [weakSelf editOption:optionID step:stepID
              block:^(NSMutableDictionary *copy, NSMutableArray *siblings) {
            (void)siblings;
            if ([value length] > 0) {
              [copy setObject:value forKey:@"purpose"];
              [copy removeObjectForKey:@"label"];
              [copy removeObjectForKey:@"icon"];
            } else {
              [copy removeObjectForKey:@"purpose"];
            }
          }];
        }];
    [sections addObject:[DBEditSection title:nil fields:@[ purposeField ]]];

    if ([purpose length] == 0) {
      [sections addObject:[DBEditSection title:[pages t:@"flow_editor.option_label"]
          fields:[pages textFields:DBFDict([option objectForKey:@"label"]) limit:kLabelLimit place:nil
                               set:^BOOL(NSString *lang, NSString *text) {
        return [weakSelf setText:text lang:lang member:@"label" step:stepID option:optionID];
      }]]];
      NSString *shown = DBFString([option objectForKey:@"icon"]);
      NSString *currentName = [DBPurposeModel iconNameForOptionPurpose:nil icon:shown];
      NSString *current = @"";
      NSMutableArray *choices = [NSMutableArray arrayWithObject:@[ @"", [pages t:@"flow_editor.icon_none"] ]];
      for (NSArray *entry in [DBPurposeModel optionIconChoices]) {
        UIImage *picture = [DBIconAsset tintedImageNamed:[entry objectAtIndex:2]
                                                   color:[UIColor darkGrayColor]
                                                    size:CGSizeMake(24, 24)];
        [choices addObject:picture != nil
            ? @[ [entry objectAtIndex:0], [pages t:[entry objectAtIndex:1]], picture ]
            : @[ [entry objectAtIndex:0], [pages t:[entry objectAtIndex:1]] ]];
        if ([currentName isEqualToString:[entry objectAtIndex:2]]) current = [entry objectAtIndex:0];
      }
      // A stored emoji is shown as the icon this shell maps it to; only a pick rewrites it.
      DBEditField *icon = [pages choice:[pages t:@"flow_editor.option_icon"] value:current
          choices:choices change:^BOOL(NSString *value) {
        return [weakSelf editOption:optionID step:stepID
            block:^(NSMutableDictionary *copy, NSMutableArray *siblings) {
          (void)siblings;
          if ([value length] == 0) [copy removeObjectForKey:@"icon"]; else [copy setObject:value forKey:@"icon"];
        }];
      }];
      [sections addObject:[DBEditSection title:nil fields:@[ icon ]]];
    }

    DBEditField *primary = [pages toggle:[pages t:@"flow_editor.option_primary"]
        value:[[option objectForKey:@"style"] isEqual:@"primary"]
        change:^BOOL(BOOL on) {
          return [weakSelf editOption:optionID step:stepID
              block:^(NSMutableDictionary *copy, NSMutableArray *siblings) {
            // One main button per page: switching it on takes it from the other option.
            if (on) for (NSMutableDictionary *other in siblings) [other removeObjectForKey:@"style"];
            if (on) [copy setObject:@"primary" forKey:@"style"]; else [copy removeObjectForKey:@"style"];
          }];
        }];
    DBEditField *enabled = [pages toggle:[pages t:@"flow_editor.option_enabled"]
        value:![[option objectForKey:@"enabled"] isEqual:@NO]
        change:^BOOL(BOOL on) {
          return [weakSelf editOption:optionID step:stepID
              block:^(NSMutableDictionary *copy, NSMutableArray *siblings) {
            (void)siblings;
            if (on) [copy removeObjectForKey:@"enabled"]; else [copy setObject:@NO forKey:@"enabled"];
          }];
        }];
    [sections addObject:[DBEditSection title:nil fields:@[ primary, enabled ]]];

    NSMutableArray *targets = [NSMutableArray array];
    for (NSString *candidate in [pages orderedStepIDs])
      if (![candidate isEqualToString:stepID]) [targets addObject:@[ candidate, [pages stepName:candidate] ]];
    DBEditField *target = [pages choice:[pages t:@"flow_editor.option_target"]
        value:DBFString([option objectForKey:@"to"]) choices:targets
        change:^BOOL(NSString *value) {
          return [weakSelf editOption:optionID step:stepID
              block:^(NSMutableDictionary *copy, NSMutableArray *siblings) {
            (void)siblings;
            [copy setObject:value forKey:@"to"];
          }];
        }];
    [sections addObject:[DBEditSection title:nil fields:@[ target ]]];

    DBEditField *remove = [pages danger:[pages t:@"editor.delete"]
                                message:[pages t:@"editor.delete_confirm"] block:^{
      DBFlowEditorPages *inner = weakSelf;
      if ([DBFArray([[inner step:stepID] objectForKey:@"options"]) count] <= 1) {
        [editor showMessage:[inner t:@"visitor_flow.no_options"]];
        return;
      }
      if ([inner editOption:optionID step:stepID
              block:^(NSMutableDictionary *copy, NSMutableArray *siblings) {
            [siblings removeObject:copy];
          }]) [editor popPage];
    }];
    [sections addObject:[DBEditSection title:nil fields:@[ remove ]]];
    return sections;
  }];
}

#pragma mark - call and notify

- (DBEditSection *)callSection:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  NSDictionary *step = [self step:stepID];
  NSMutableArray *purposes = [NSMutableArray arrayWithObject:
      @[ @"", [self t:@"flow_editor.purpose_none"] ]];
  NSDictionary *visit = DBFDict([[self cfg] objectForKey:@"visit_purposes"]);
  for (NSString *identifier in [DBConfigUtil sortedByOrder:visit])
    [purposes addObject:@[ identifier, [self purposeLabel:identifier] ]];
  DBEditField *purpose = [self choice:[self t:@"flow_editor.field_purpose"]
      value:DBFString([step objectForKey:@"purpose"]) choices:purposes
      change:^BOOL(NSString *value) {
        return [weakSelf editStep:stepID block:^(NSMutableDictionary *copy) {
          if ([value length] == 0) [copy removeObjectForKey:@"purpose"];
          else [copy setObject:value forKey:@"purpose"];
        }];
      }];
  NSMutableArray *pageChoices = [NSMutableArray arrayWithObject:
      @[ @"", [self t:@"flow_editor.on_unanswered_none"] ]];
  [pageChoices addObjectsFromArray:[self stepChoicesOfKind:@"page"]];
  DBEditField *unanswered = [self choice:[self t:@"flow_editor.field_on_unanswered"]
      value:DBFString([step objectForKey:@"on_unanswered"]) choices:pageChoices
      change:^BOOL(NSString *value) {
        return [weakSelf editStep:stepID block:^(NSMutableDictionary *copy) {
          if ([value length] == 0) [copy removeObjectForKey:@"on_unanswered"];
          else [copy setObject:value forKey:@"on_unanswered"];
        }];
      }];
  return [DBEditSection title:nil fields:@[ purpose, unanswered ]];
}

// Cameras Core can take a still from: the media sources with a snapshot URL.
- (NSArray *)snapshotCameraChoices {
  NSMutableArray *choices = [NSMutableArray arrayWithObjects:
      @[ @"", [self t:@"flow_editor.snapshot_none"] ],
      @[ @"door_station", [self t:@"flow_editor.snapshot_door_station"] ], nil];
  NSDictionary *sources = DBFDict([[self cfg] objectForKey:@"media_sources"]);
  for (NSString *source in [[sources allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSString *url = DBFString([DBFDict([DBFDict([DBFDict([sources objectForKey:source])
        objectForKey:@"streams"]) objectForKey:@"snapshot"]) objectForKey:@"url"]);
    if ([url length] == 0) continue;
    [choices addObject:@[ [@"media_source:" stringByAppendingString:source],
                          [_texts t:@"flow_editor.snapshot_camera", source, nil] ]];
  }
  return choices;
}

- (DBEditSection *)notifySection:(NSString *)stepID {
  __weak DBFlowEditorPages *weakSelf = self;
  NSDictionary *step = [self step:stepID];
  NSMutableArray *purposes = [NSMutableArray arrayWithObject:
      @[ @"", [self t:@"flow_editor.purpose_none"] ]];
  NSDictionary *visit = DBFDict([[self cfg] objectForKey:@"visit_purposes"]);
  for (NSString *identifier in [DBConfigUtil sortedByOrder:visit])
    [purposes addObject:@[ identifier, [self purposeLabel:identifier] ]];
  DBEditField *purpose = [self choice:[self t:@"flow_editor.field_purpose"]
      value:DBFString([step objectForKey:@"purpose"]) choices:purposes
      change:^BOOL(NSString *value) {
        return [weakSelf editStep:stepID block:^(NSMutableDictionary *copy) {
          if ([value length] == 0) [copy removeObjectForKey:@"purpose"];
          else [copy setObject:value forKey:@"purpose"];
        }];
      }];
  NSDictionary *snapshot = DBFDict([step objectForKey:@"snapshot"]);
  NSString *source = DBFString([snapshot objectForKey:@"source"]);
  NSString *current = [source isEqualToString:@"media_source"]
      ? [@"media_source:" stringByAppendingString:DBFString([snapshot objectForKey:@"id"])]
      : source;
  NSArray *cameras = [self snapshotCameraChoices];
  DBEditField *camera = [self choice:[self t:@"flow_editor.field_snapshot"] value:current
      choices:cameras change:^BOOL(NSString *value) {
        return [weakSelf editStep:stepID block:^(NSMutableDictionary *copy) {
          if ([value length] == 0) {
            [copy removeObjectForKey:@"snapshot"];
          } else if ([value isEqualToString:@"door_station"]) {
            [copy setObject:@{ @"source" : @"door_station" } forKey:@"snapshot"];
          } else {
            [copy setObject:@{ @"source" : @"media_source",
                               @"id" : [value substringFromIndex:[@"media_source:" length]] }
                     forKey:@"snapshot"];
          }
        }];
      }];
  DBEditField *to = [self choice:[self t:@"flow_editor.field_to"]
      value:DBFString([step objectForKey:@"to"]) choices:[self stepChoicesOfKind:@"end"]
      change:^BOOL(NSString *value) {
        return [weakSelf editStep:stepID block:^(NSMutableDictionary *copy) {
          [copy setObject:value forKey:@"to"];
        }];
      }];
  DBEditSection *section = [DBEditSection title:nil fields:@[ purpose, camera, to ]];
  if ([cameras count] <= 2) section.footer = [self t:@"flow_editor.snapshot_no_camera"];
  return section;
}

@end
