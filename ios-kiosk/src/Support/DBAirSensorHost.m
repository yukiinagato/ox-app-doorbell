#import "DBAirSensorHost.h"

#import <CoreBluetooth/CoreBluetooth.h>

#import "../Core/DBConfigUtil.h"
#import "../Core/DBCoreBridge.h"

static NSString *const kHandlerKey = @"air_sensor_host";
static const NSTimeInterval kScanBurstS = 10;
static const NSTimeInterval kScanEveryS = 180;
static const NSTimeInterval kTickS = 30;

static NSString *DBAirString(id value, NSString *fallback) {
  return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 ? value
                                                                                   : fallback;
}

// The plan as plain values, so two plans compare with isEqual:.
static NSDictionary *DBAirPlanFromDocument(NSDictionary *doc) {
  NSMutableArray *sensors = [NSMutableArray array];
  id list = [doc isKindOfClass:[NSDictionary class]] ? [doc objectForKey:@"sensors"] : nil;
  if ([list isKindOfClass:[NSArray class]]) {
    for (id entry in (NSArray *)list) {
      if (![entry isKindOfClass:[NSDictionary class]]) continue;
      NSString *sensorId = DBAirString([entry objectForKey:@"id"], nil);
      if (sensorId == nil) continue;
      [sensors addObject:@{ @"id" : sensorId,
                            @"address" : DBAirString([entry objectForKey:@"address"], @""),
                            @"kind" : DBAirString([entry objectForKey:@"kind"], @"") }];
    }
  }
  NSDictionary *gatt = [doc isKindOfClass:[NSDictionary class]]
      ? [doc objectForKey:@"mops_vida_pm25"] : nil;
  if (![gatt isKindOfClass:[NSDictionary class]]) gatt = nil;
  return @{
    @"host" : @([DBConfigUtil evBool:doc key:@"host"]),
    @"scan" : @([DBConfigUtil evBool:doc key:@"scan"]),
    @"sensors" : sensors,
    @"advertised_service" : DBAirString([gatt objectForKey:@"advertised_service"], @"7676"),
    @"service" : DBAirString([gatt objectForKey:@"service"],
                             @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
    @"rx" : DBAirString([gatt objectForKey:@"rx"], @"6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
    @"tx" : DBAirString([gatt objectForKey:@"tx"], @"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
  };
}

static BOOL DBSameUUID(CBUUID *a, CBUUID *b) {
  return a != nil && b != nil && [[a data] isEqualToData:[b data]];
}

// Peripheral identity differs by OS: iOS 7 and later expose an NSUUID `identifier`; iOS 5 and 6
// expose a CFUUIDRef `UUID`, which stays NULL until the peripheral has been connected once.
static NSString *DBPeripheralAddress(CBPeripheral *peripheral) {
  if ([peripheral respondsToSelector:@selector(identifier)]) return [peripheral.identifier UUIDString];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CFUUIDRef uuid = peripheral.UUID;
#pragma clang diagnostic pop
  if (uuid == NULL) return nil;
  return (NSString *)CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
}

static NSString *DBBleState(CBCentralManager *central) {
  if (central == nil) return @"unknown";
  switch ((NSInteger)central.state) {
    case 5: return @"ready";
    case 4: return @"off";
    case 3: return @"unauthorized";
    case 2: return @"unsupported";
    default: return @"unknown";
  }
}

@interface DBAirSensorLink : NSObject
@property(nonatomic, copy) NSString *sensorId;
@property(nonatomic, copy) NSString *address;
@property(nonatomic, copy) NSDictionary *sensor;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) CBCharacteristic *rx;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, assign) NSInteger failures;
@property(nonatomic, assign) BOOL commandSent;
@property(nonatomic, assign) BOOL retrieving;
@property(nonatomic, assign) NSUInteger retryGeneration;
@end

@implementation DBAirSensorLink
@synthesize sensorId = _sensorId, address = _address, sensor = _sensor,
            peripheral = _peripheral, rx = _rx, state = _state, failures = _failures,
            commandSent = _commandSent, retrieving = _retrieving,
            retryGeneration = _retryGeneration;
@end

@interface DBAirSensorHost () <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

@implementation DBAirSensorHost {
  DBCoreBridge *_core;
  dispatch_queue_t _queue;
  dispatch_source_t _ticker;
  BOOL _running;
  NSDictionary *_plan;
  CBCentralManager *_central;
  NSMutableDictionary *_links;       // sensor id -> DBAirSensorLink
  NSMutableDictionary *_discovered;  // address -> {address, name, rssi}
  BOOL _scanning;
  NSUInteger _scanGeneration;
  NSTimeInterval _lastScanStart;
}

- (id)initWithCore:(DBCoreBridge *)core {
  self = [super init];
  if (self) {
    _core = core;
    _queue = dispatch_queue_create("jp.ox.doorbell.air-sensor", DISPATCH_QUEUE_SERIAL);
    _links = [[NSMutableDictionary alloc] init];
    _discovered = [[NSMutableDictionary alloc] init];
    _plan = DBAirPlanFromDocument(nil);
    _lastScanStart = -1e9;
  }
  return self;
}

- (void)start {
  __weak DBAirSensorHost *weakSelf = self;
  dispatch_queue_t queue = _queue;
  [_core addHandler:kHandlerKey handler:^(NSDictionary *ev) {
    if (![[DBConfigUtil evStr:ev key:@"t"] isEqualToString:@"air_sensor_plan_changed"]) return;
    dispatch_async(queue, ^{ [weakSelf refreshPlan]; });
  }];
  dispatch_async(_queue, ^{
    DBAirSensorHost *host = weakSelf;
    if (!host || host->_running) return;
    host->_running = YES;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     host->_queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)(kTickS * NSEC_PER_SEC)),
                              (uint64_t)(kTickS * NSEC_PER_SEC), NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ [weakSelf tick]; });
    dispatch_resume(timer);
    host->_ticker = timer;
    [host refreshPlan];
  });
}

- (void)stop {
  [_core removeHandler:kHandlerKey];
  dispatch_async(_queue, ^{
    self->_running = NO;
    if (self->_ticker) dispatch_source_cancel(self->_ticker);
    self->_ticker = nil;
    [self releaseAll];
  });
}

#pragma mark - plan

- (BOOL)planHost {
  return [[_plan objectForKey:@"host"] boolValue];
}

- (BOOL)planScan {
  return [[_plan objectForKey:@"scan"] boolValue];
}

- (NSTimeInterval)uptime {
  return [[NSProcessInfo processInfo] systemUptime];
}

// The plan is re-read on every tick as well as on the event, so a plan published before the
// handler was registered is still picked up.
- (void)tick {
  [self refreshPlan];
  if (!_running || ![self planHost] || ![self planScan]) return;
  if ([self uptime] - _lastScanStart >= kScanEveryS) [self startScanBurst];
}

- (void)refreshPlan {
  if (!_running) return;
  NSDictionary *next = DBAirPlanFromDocument([_core airSensorPlan]);
  if (![[next objectForKey:@"host"] boolValue]) {
    if (_central != nil) [self releaseAll];
    _plan = next;
    return;
  }
  NSDictionary *previous = _plan;
  _plan = next;
  if (_central == nil) {
    // The power alert is an iOS 7 option; the literal is its documented value, so no iOS 7
    // symbol is referenced on iOS 5.
    if ([CBCentralManager instancesRespondToSelector:@selector(initWithDelegate:queue:options:)])
      _central = [[CBCentralManager alloc] initWithDelegate:self queue:_queue
          options:@{ @"kCBInitOptionShowPowerAlert" : @NO }];
    else
      _central = [[CBCentralManager alloc] initWithDelegate:self queue:_queue];
  }
  [self reconcileLinks];
  BOOL changed = ![next isEqual:previous];
  if ([self planScan] && (![[previous objectForKey:@"scan"] boolValue] || changed)) {
    [self startScanBurst];
  } else if (![self planScan]) {
    [self stopScan];
    [_discovered removeAllObjects];
  }
  if (changed) [self report];
}

- (void)reconcileLinks {
  NSMutableDictionary *wanted = [NSMutableDictionary dictionary];
  for (NSDictionary *sensor in [_plan objectForKey:@"sensors"])
    if ([wanted objectForKey:[sensor objectForKey:@"id"]] == nil)
      [wanted setObject:sensor forKey:[sensor objectForKey:@"id"]];
  for (NSString *sensorId in [_links allKeys]) {
    DBAirSensorLink *link = [_links objectForKey:sensorId];
    if ([link.sensor isEqual:[wanted objectForKey:sensorId]]) continue;
    [self drop:link];
    [_links removeObjectForKey:sensorId];
  }
  for (NSString *sensorId in wanted) {
    if ([_links objectForKey:sensorId] != nil) continue;
    NSDictionary *sensor = [wanted objectForKey:sensorId];
    DBAirSensorLink *link = [[DBAirSensorLink alloc] init];
    link.sensorId = sensorId;
    link.address = [sensor objectForKey:@"address"];
    link.sensor = sensor;
    link.state = @"disconnected";
    [_links setObject:link forKey:sensorId];
    [self connect:link];
  }
}

- (void)releaseAll {
  [self stopScan];
  for (DBAirSensorLink *link in [_links allValues]) [self drop:link];
  [_links removeAllObjects];
  [_discovered removeAllObjects];
  _central.delegate = nil;
  _central = nil;
}

- (void)drop:(DBAirSensorLink *)link {
  link.retryGeneration++;
  link.retrieving = NO;
  if (link.peripheral != nil) {
    link.peripheral.delegate = nil;
    [_central cancelPeripheralConnection:link.peripheral];
  }
  link.peripheral = nil;
  link.rx = nil;
}

- (BOOL)poweredOn {
  return [DBBleState(_central) isEqualToString:@"ready"];
}

#pragma mark - scanning

- (void)startScanBurst {
  if (![self planScan] || ![self poweredOn]) return;
  _lastScanStart = [self uptime];
  [_discovered removeAllObjects];
  NSUInteger generation = ++_scanGeneration;
  [_central scanForPeripheralsWithServices:
                @[ [CBUUID UUIDWithString:[_plan objectForKey:@"advertised_service"]] ]
                                   options:@{ CBCentralManagerScanOptionAllowDuplicatesKey : @NO }];
  _scanning = YES;
  __weak DBAirSensorHost *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kScanBurstS * NSEC_PER_SEC)), _queue,
                 ^{
    DBAirSensorHost *host = weakSelf;
    if (!host || generation != host->_scanGeneration) return;
    [host stopScan];
    [host report];
  });
}

- (void)stopScan {
  _scanGeneration++;
  if (_scanning && [self poweredOn]) [_central stopScan];
  _scanning = NO;
}

#pragma mark - links

- (void)connect:(DBAirSensorLink *)link {
  link.retryGeneration++;
  if (!_running || [_links objectForKey:link.sensorId] != link || ![self poweredOn]) return;
  NSString *address = link.address;
  if ([_central respondsToSelector:@selector(retrievePeripheralsWithIdentifiers:)]) {
    Class uuidClass = NSClassFromString(@"NSUUID");
    id uuid = [address length] > 0 ? [[uuidClass alloc] initWithUUIDString:address] : nil;
    NSArray *found = uuid ? [_central retrievePeripheralsWithIdentifiers:@[ uuid ]] : nil;
    if ([found count] == 0) {
      // Only a peripheral this device has seen can be retrieved; a later scan may find it.
      [self setState:@"not_found" forLink:link];
      [self scheduleRetry:link];
      return;
    }
    [self attach:[found objectAtIndex:0] toLink:link];
    return;
  }
  // iOS 5 and 6 answer retrievePeripherals: asynchronously in didRetrievePeripherals:.
  CFUUIDRef uuid = [address length] > 0
      ? CFUUIDCreateFromString(NULL, (__bridge CFStringRef)address) : NULL;
  if (uuid == NULL) {
    [self setState:@"not_found" forLink:link];
    [self scheduleRetry:link];
    return;
  }
  link.retrieving = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [_central retrievePeripherals:@[ (__bridge id)uuid ]];
#pragma clang diagnostic pop
  CFRelease(uuid);
  // A retrieval that never answers falls back to the retry schedule.
  [self scheduleRetry:link];
}

- (void)attach:(CBPeripheral *)peripheral toLink:(DBAirSensorLink *)link {
  link.retryGeneration++;
  link.retrieving = NO;
  link.peripheral = peripheral;
  link.rx = nil;
  link.commandSent = NO;
  peripheral.delegate = self;
  [self setState:@"connecting" forLink:link];
  [_central connectPeripheral:peripheral options:nil];
}

- (void)scheduleRetry:(DBAirSensorLink *)link {
  static const NSTimeInterval delays[] = { 2, 5, 10, 30, 60, 120 };
  const NSInteger count = (NSInteger)(sizeof(delays) / sizeof(delays[0]));
  NSTimeInterval delay = delays[MIN(link.failures, count - 1)];
  link.failures++;
  NSUInteger generation = ++link.retryGeneration;
  __weak DBAirSensorHost *weakSelf = self;
  __weak DBAirSensorLink *weakLink = link;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
    DBAirSensorLink *target = weakLink;
    if (!target || target.retryGeneration != generation || target.peripheral != nil) return;
    target.retrieving = NO;
    [weakSelf connect:target];
  });
}

- (void)linkLost:(DBAirSensorLink *)link {
  if (link.peripheral != nil) {
    link.peripheral.delegate = nil;
    [_central cancelPeripheralConnection:link.peripheral];
  }
  link.peripheral = nil;
  link.rx = nil;
  [self setState:@"disconnected" forLink:link];
  [self scheduleRetry:link];
}

- (DBAirSensorLink *)linkForPeripheral:(CBPeripheral *)peripheral {
  for (DBAirSensorLink *link in [_links allValues])
    if (link.peripheral == peripheral) return link;
  return nil;
}

- (void)setState:(NSString *)state forLink:(DBAirSensorLink *)link {
  if ([link.state isEqualToString:state]) return;
  link.state = state;
  [self report];
}

#pragma mark - report

- (void)report {
  if (!_running || ![self planHost]) return;
  NSMutableDictionary *links = [NSMutableDictionary dictionary];
  for (NSString *sensorId in _links)
    [links setObject:[(DBAirSensorLink *)[_links objectForKey:sensorId] state] forKey:sensorId];
  NSMutableDictionary *doc = [NSMutableDictionary dictionaryWithObjectsAndKeys:
      DBBleState(_central), @"ble", links, @"links", nil];
  if ([self planScan]) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *address in [[_discovered allKeys] sortedArrayUsingSelector:@selector(compare:)])
      [found addObject:[_discovered objectForKey:address]];
    [doc setObject:found forKey:@"discovered"];
  }
  [_core airSensorReport:doc];
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  if (central != _central) return;
  if ([self poweredOn]) {
    for (DBAirSensorLink *link in [_links allValues]) {
      if (link.peripheral != nil) continue;
      link.failures = 0;
      [self connect:link];
    }
    if ([self planScan]) [self startScanBurst];
  } else {
    // Peripherals handed out before the adapter went away are invalid afterwards.
    _scanning = NO;
    _scanGeneration++;
    for (DBAirSensorLink *link in [_links allValues]) {
      link.retryGeneration++;
      link.retrieving = NO;
      link.peripheral.delegate = nil;
      link.peripheral = nil;
      link.rx = nil;
      link.state = @"disconnected";
    }
  }
  [self report];
}

- (void)centralManager:(CBCentralManager *)central didRetrievePeripherals:(NSArray *)peripherals {
  if (central != _central) return;
  for (DBAirSensorLink *link in [_links allValues]) {
    if (!link.retrieving || link.peripheral != nil) continue;
    for (CBPeripheral *peripheral in peripherals) {
      NSString *address = DBPeripheralAddress(peripheral);
      if (address == nil || [address caseInsensitiveCompare:link.address] != NSOrderedSame)
        continue;
      [self attach:peripheral toLink:link];
      break;
    }
    if (link.peripheral == nil) {
      link.retrieving = NO;
      [self setState:@"not_found" forLink:link];
    }
  }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary *)advertisementData
                     RSSI:(NSNumber *)RSSI {
  if (central != _central || ![self planScan]) return;
  NSString *address = DBPeripheralAddress(peripheral);
  if ([address length] == 0) return;
  NSString *name = peripheral.name;
  if ([name length] == 0) name = DBAirString([advertisementData
      objectForKey:CBAdvertisementDataLocalNameKey], @"");
  BOOL isNew = [_discovered objectForKey:address] == nil;
  [_discovered setObject:@{ @"address" : address, @"name" : name,
                            @"rssi" : @([RSSI integerValue]) }
                  forKey:address];
  if (isNew) [self report];
  // A sensor assigned before this device had ever seen it becomes retrievable now.
  for (DBAirSensorLink *link in [_links allValues]) {
    if ([link.address caseInsensitiveCompare:address] != NSOrderedSame ||
        ![link.state isEqualToString:@"not_found"])
      continue;
    link.failures = 0;
    [self attach:peripheral toLink:link];
  }
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
  if (central != _central || [self linkForPeripheral:peripheral] == nil) return;
  [peripheral discoverServices:@[ [CBUUID UUIDWithString:[_plan objectForKey:@"service"]] ]];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error {
  (void)error;
  if (central != _central) return;
  DBAirSensorLink *link = [self linkForPeripheral:peripheral];
  if (link) [self linkLost:link];
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
  (void)error;
  if (central != _central) return;
  DBAirSensorLink *link = [self linkForPeripheral:peripheral];
  if (link) [self linkLost:link];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
  DBAirSensorLink *link = [self linkForPeripheral:peripheral];
  if (!link) return;
  CBUUID *serviceId = [CBUUID UUIDWithString:[_plan objectForKey:@"service"]];
  CBService *found = nil;
  if (error == nil)
    for (CBService *service in peripheral.services)
      if (DBSameUUID(service.UUID, serviceId)) found = service;
  if (found == nil) {
    [self linkLost:link];
    return;
  }
  [peripheral discoverCharacteristics:@[ [CBUUID UUIDWithString:[_plan objectForKey:@"rx"]],
                                         [CBUUID UUIDWithString:[_plan objectForKey:@"tx"]] ]
                           forService:found];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service
                                   error:(NSError *)error {
  DBAirSensorLink *link = [self linkForPeripheral:peripheral];
  if (!link) return;
  CBUUID *rxId = [CBUUID UUIDWithString:[_plan objectForKey:@"rx"]];
  CBUUID *txId = [CBUUID UUIDWithString:[_plan objectForKey:@"tx"]];
  CBCharacteristic *rx = nil, *tx = nil;
  if (error == nil) {
    for (CBCharacteristic *characteristic in service.characteristics) {
      if (DBSameUUID(characteristic.UUID, rxId)) rx = characteristic;
      if (DBSameUUID(characteristic.UUID, txId)) tx = characteristic;
    }
  }
  if (rx == nil || tx == nil) {
    [self linkLost:link];
    return;
  }
  link.rx = rx;
  [peripheral setNotifyValue:YES forCharacteristic:tx];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
                                          error:(NSError *)error {
  DBAirSensorLink *link = [self linkForPeripheral:peripheral];
  if (!link || !DBSameUUID(characteristic.UUID,
                           [CBUUID UUIDWithString:[_plan objectForKey:@"tx"]]))
    return;
  if (error != nil || !characteristic.isNotifying) {
    [self linkLost:link];
    return;
  }
  if (!link.commandSent && link.rx != nil) {
    NSData *command = [_core airSensorConnectCommand];
    if (command != nil) {
      CBCharacteristicWriteType type = (link.rx.properties & CBCharacteristicPropertyWrite)
          ? CBCharacteristicWriteWithResponse : CBCharacteristicWriteWithoutResponse;
      [peripheral writeValue:command forCharacteristic:link.rx type:type];
      link.commandSent = YES;
    }
  }
  link.failures = 0;
  [self setState:@"connected" forLink:link];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
                              error:(NSError *)error {
  if (error != nil) return;
  DBAirSensorLink *link = [self linkForPeripheral:peripheral];
  if (!link || !DBSameUUID(characteristic.UUID,
                           [CBUUID UUIDWithString:[_plan objectForKey:@"tx"]]))
    return;
  NSData *value = characteristic.value;
  if ([value length] > 0) [_core airSensorPacket:value sensorId:link.sensorId];
}

@end
