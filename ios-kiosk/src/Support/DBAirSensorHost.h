#import <Foundation/Foundation.h>

@class DBCoreBridge;

// GATT plumbing for the Bluetooth PM2.5 sensors Core assigns to this device
// (db_core_air_sensor_plan_json). Core owns the plan, the protocol and the readings; this only
// scans, keeps one link per listed sensor, and forwards raw notifications.
//
// Threading: every CoreBluetooth callback, timer and Core call runs on one private serial
// queue. No CBCentralManager exists until Core names this device a host.
@interface DBAirSensorHost : NSObject

- (id)initWithCore:(DBCoreBridge *)core;
- (void)start;
- (void)stop;

@end
