#import <Foundation/Foundation.h>

// Whether this hardware has a Bluetooth LE radio, judged from the hw.machine identifier.
// CoreBluetooth exists on every iOS 5+ device, and on hardware without LE it only reports
// "unsupported" after a CBCentralManager has been created, so the decision is made from the
// model instead: the kiosk advertises ble_air_sensor_v1 only where hosting can work.
BOOL DBMachineHasBluetoothLE(NSString *machine);
BOOL DBDeviceHasBluetoothLE(void);
NSString *DBDeviceMachine(void);
