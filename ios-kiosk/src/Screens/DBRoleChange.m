#import "DBRoleChange.h"

#import <UIKit/UIKit.h>

#import "../Core/DBBootConfig.h"
#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"
#import "../Core/DBTexts.h"
#import "../Support/DBAppDelegate.h"
#import "DBEditor.h"
#import "DBRouter.h"

static NSString *const kDBRoleDoor = @"door_station";
static NSString *const kDBRoleIndoor = @"indoor_panel";

@implementation DBRoleChange {
  __weak DBRouter *_router;
  __weak DBEditorView *_editor;
  DBCoreBridge *_core;
  DBBootConfig *_boot;
  DBTexts *_texts;
  NSDictionary *_cfg;
  NSDictionary *_status;
  NSString *_nodeId;
  // The pending choice; boot.json keeps the running identity until Confirm.
  NSString *_role;
  NSString *_door;
  NSString *_newDoor;
}

- (id)initWithRouter:(DBRouter *)router editor:(DBEditorView *)editor {
  self = [super init];
  if (self) {
    _router = router;
    _editor = editor;
    _core = router.core;
    _boot = router.boot;
    _texts = router.texts;
  }
  return self;
}

- (BOOL)isStation:(NSString *)role {
  return [role isEqualToString:kDBRoleDoor];
}

- (NSDictionary *)doors {
  id doors = [_cfg objectForKey:@"doors"];
  return [doors isKindOfClass:[NSDictionary class]] ? doors : @{};
}

- (NSString *)labelForDoor:(NSString *)door {
  id entry = [[self doors] objectForKey:door];
  return entry ? [DBConfigUtil labelOf:entry lang:_boot.uiLang fallback:door] : door;
}

// Another device that is configured as the door station of that door, or nil.
- (NSString *)otherStationForDoor:(NSString *)door liveOnly:(BOOL)liveOnly {
  id devices = [_cfg objectForKey:@"devices"];
  if (![devices isKindOfClass:[NSDictionary class]] || [door length] == 0) return nil;
  for (NSString *device in [[(NSDictionary *)devices allKeys]
           sortedArrayUsingSelector:@selector(compare:)]) {
    if ([device isEqualToString:_nodeId]) continue;
    id entry = [(NSDictionary *)devices objectForKey:device];
    if (![entry isKindOfClass:[NSDictionary class]]) continue;
    if (![self isStation:[DBConfigUtil str:entry path:@"role"]] ||
        ![door isEqualToString:[DBConfigUtil str:entry path:@"door"] ?: @""])
      continue;
    if (liveOnly) {
      NSDictionary *peer = [DBConfigUtil findPeer:_status nodeId:device];
      if (!peer || ![DBConfigUtil boolVal:peer path:@"alive" def:YES]) continue;
    }
    return device;
  }
  return nil;
}

- (NSString *)nameOfDevice:(NSString *)device {
  NSString *name = [DBConfigUtil str:_cfg path:[NSString stringWithFormat:@"devices.%@.name",
                                                                           device]];
  return [name length] > 0 ? name : device;
}

// Configured doors no live door station serves, plus the door this device serves now.
- (NSArray *)availableDoors {
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *door in [DBConfigUtil sortedByOrder:[self doors]]) {
    if (![DBBootConfig isValidDoor:door]) continue;
    BOOL mine = [self isStation:_boot.role] && [door isEqualToString:_boot.door];
    if (mine || [self otherStationForDoor:door liveOnly:YES] == nil) [out addObject:door];
  }
  return out;
}

- (DBEditPage *)pageWithConfig:(NSDictionary *)config status:(NSDictionary *)status
                        nodeId:(NSString *)nodeId {
  _cfg = [config isKindOfClass:[NSDictionary class]] ? config : @{};
  _status = [status isKindOfClass:[NSDictionary class]] ? status : @{};
  _nodeId = [nodeId copy] ?: @"";
  _role = [DBBootConfig isValidRole:_boot.role] ? [_boot.role copy] : kDBRoleIndoor;
  // The suggestion is the shell's own "door-xxxxxxxx" form; one that names a configured door
  // is this device's current door, so a new id is drawn instead.
  NSString *suggested = _boot.suggestedDoor;
  if (![DBBootConfig isValidDoor:suggested] || [[self doors] objectForKey:suggested] != nil)
    suggested = [DBBootConfig suggestedDeviceNameForRole:kDBRoleDoor identifier:nil];
  _newDoor = [suggested copy];
  NSArray *available = [self availableDoors];
  if ([self isStation:_role] && [DBBootConfig isValidDoor:_boot.door]) {
    _door = [_boot.door copy];
  } else {
    _door = [available count] > 0 ? [[available objectAtIndex:0] copy] : [_newDoor copy];
  }

  __weak DBRoleChange *weakSelf = self;
  return [DBEditPage title:[_texts ts:@"settings.change_role"] build:^NSArray *{
    DBRoleChange *form = weakSelf;
    return form ? [form sections] : @[];
  }];
}

- (DBEditField *)choice:(NSString *)title checked:(BOOL)checked then:(void (^)(void))then {
  DBEditField *field = [DBEditField kind:DBEditKindAction title:title value:nil];
  field.checked = checked;
  __weak DBEditorView *editor = _editor;
  field.action = ^{
    then();
    [editor reloadPage];
  };
  return field;
}

- (NSArray *)sections {
  __weak DBRoleChange *weakSelf = self;
  NSMutableArray *sections = [NSMutableArray array];

  NSMutableArray *roles = [NSMutableArray array];
  for (NSArray *role in @[ @[ kDBRoleIndoor, @"settings.role_indoor" ],
                           @[ kDBRoleDoor, @"settings.role_door" ] ]) {
    NSString *value = [role objectAtIndex:0];
    [roles addObject:[self choice:[_texts ts:[role objectAtIndex:1]]
                          checked:[_role isEqualToString:value]
                             then:^{
      DBRoleChange *form = weakSelf;
      if (form) form->_role = value;
    }]];
  }
  DBEditSection *roleSection = [DBEditSection title:[_texts ts:@"settings.device_role"]
                                             fields:roles];
  if (![self isStation:_role]) roleSection.footer = [_texts ts:@"settings.role_indoor_note"];
  [sections addObject:roleSection];

  if ([self isStation:_role]) {
    NSMutableArray *doors = [NSMutableArray array];
    NSArray *available = [self availableDoors];
    for (NSString *door in available) {
      DBEditField *field = [self choice:[self labelForDoor:door]
                                checked:[_door isEqualToString:door]
                                   then:^{
        DBRoleChange *form = weakSelf;
        if (form) form->_door = door;
      }];
      if (![[self labelForDoor:door] isEqualToString:door]) field.detail = door;
      [doors addObject:field];
    }
    // An unpaired device has no door list: the new door and its typed id are the whole form.
    BOOL newChosen = ![available containsObject:_door];
    NSString *newDoor = _newDoor;
    DBEditField *fresh = [self choice:[_texts ts:@"settings.role_new_door"] checked:newChosen
                                 then:^{
      DBRoleChange *form = weakSelf;
      if (form) form->_door = newDoor;
    }];
    fresh.detail = _newDoor;
    [doors addObject:fresh];
    DBEditField *identifier = [DBEditField kind:DBEditKindText
                                          title:[_texts ts:@"settings.role_new_door_id"]
                                          value:_newDoor];
    identifier.keyboard = UIKeyboardTypeASCIICapable;
    identifier.placeholder = _newDoor;
    __weak DBEditorView *editor = _editor;
    identifier.onChange = ^BOOL(id value) {
      DBRoleChange *form = weakSelf;
      if (!form) return NO;
      NSString *door = [[value description] stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (![DBBootConfig isValidDoor:door]) {
        [editor showMessage:[form->_texts ts:@"editor.id_hint"]];
        return NO;
      }
      form->_newDoor = door;
      form->_door = door;
      return YES;
    };
    [doors addObject:identifier];
    DBEditSection *doorSection = [DBEditSection title:[_texts ts:@"settings.device_door"]
                                               fields:doors];
    doorSection.footer = [self doorWarning];
    [sections addObject:doorSection];
  }

  DBEditField *apply = [DBEditField kind:DBEditKindAction
                                   title:[_texts ts:@"settings.change_role"] value:nil];
  apply.action = ^{ [weakSelf confirm]; };
  DBEditSection *applySection = [DBEditSection title:nil fields:@[ apply ]];
  applySection.footer = [_texts ts:@"settings.role_restart"];
  [sections addObject:applySection];
  return sections;
}

// The chosen door already has a door station: allowed, but said before and at Confirm.
- (NSString *)doorWarning {
  if (![self isStation:_role]) return nil;
  NSString *other = [self otherStationForDoor:_door liveOnly:NO];
  if (other == nil) return nil;
  return [_texts t:@"settings.role_door_in_use", [self nameOfDevice:other], nil];
}

// A call is read from Core's active calls and the screen on top, an SOS from
// status.emergency.active, and pairing from the pairing state machine.
- (BOOL)busyWithStatus:(NSDictionary *)status pairing:(NSDictionary *)pairing {
  id calls = [status objectForKey:@"active_calls"];
  if ([calls isKindOfClass:[NSArray class]] && [(NSArray *)calls count] > 0) return YES;
  if ([DBConfigUtil boolVal:status path:@"emergency.active" def:NO]) return YES;
  if ([[DBConfigUtil str:pairing path:@"state"] isEqualToString:@"joining"]) return YES;
  NSString *screen = [_router currentScreenName] ?: @"";
  for (NSString *busy in @[ @"incoming", @"call", @"pairing", @"add_device" ])
    if ([screen rangeOfString:busy].location != NSNotFound) return YES;
  return NO;
}

- (void)confirm {
  BOOL station = [self isStation:_role];
  NSString *door = station ? (_door ?: @"") : @"";
  if (station && ![DBBootConfig isValidDoor:door]) {
    [_editor showMessage:[_texts ts:@"editor.id_hint"]];
    return;
  }
  BOOL roleChanged = ![_role isEqualToString:_boot.role];
  if (!roleChanged && [door isEqualToString:_boot.door ?: @""]) {
    [_editor showMessage:[_texts ts:@"settings.role_unchanged"]];
    return;
  }
  NSString *role = _role;
  DBCoreBridge *core = _core;
  __weak DBRoleChange *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSDictionary *status = [core status];
    NSDictionary *pairing = [core pairingInfo];
    dispatch_async(dispatch_get_main_queue(), ^{
      DBRoleChange *form = weakSelf;
      if (!form) return;
      if ([form busyWithStatus:status pairing:pairing]) {
        [form->_editor showMessage:[form->_texts ts:@"settings.role_busy"]];
        return;
      }
      NSMutableArray *lines = [NSMutableArray array];
      [lines addObject:[form->_texts ts:(roleChanged ? @"settings.role_restart_confirm"
                                                     : @"settings.door_restart_confirm")]];
      if (roleChanged && !station)
        [lines addObject:[form->_texts ts:@"settings.role_door_kept_note"]];
      NSString *warning = [form doorWarning];
      if (warning) [lines addObject:warning];
      [form->_editor confirmTitle:[form->_texts ts:@"settings.change_role"]
                          message:[lines componentsJoinedByString:@"\n\n"]
                             then:^{ [weakSelf applyRole:role door:door]; }];
    });
  });
}

- (void)applyRole:(NSString *)role door:(NSString *)door {
  if ([self busyWithStatus:[_core lastStatus] pairing:nil]) {
    [_editor showMessage:[_texts ts:@"settings.role_busy"]];
    return;
  }
  DBAppDelegate *app = (DBAppDelegate *)[UIApplication sharedApplication].delegate;
  if (![app isKindOfClass:[DBAppDelegate class]] ||
      ![app applyLocalIdentityName:_boot.name role:role door:door])
    [_editor showMessage:[_texts ts:@"settings.save_failed"]];
}

@end
