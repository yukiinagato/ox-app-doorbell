#import "DBBluetoothSupport.h"

#include <stdlib.h>
#include <sys/sysctl.h>

NSString *DBDeviceMachine(void) {
  size_t size = 0;
  if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return nil;
  char *buf = (char *)malloc(size);
  if (buf == NULL) return nil;
  NSString *machine = nil;
  if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0)
    machine = [NSString stringWithUTF8String:buf];
  free(buf);
  return [machine length] > 0 ? machine : nil;
}

// Hardware workaround: the first-generation iPad (iPad1,x) and the iPad 2 (iPad2,1-2,4) have
// Bluetooth 2.1 only. Every later iPad has Bluetooth 4.0 LE: the iPad mini 1 (iPad2,5-2,7) and
// every iPad3,x and later. iPhones have it from the 4S (iPhone4,1) and iPod touches from the
// fifth generation (iPod5,1). Simulators and unknown families are treated as having none.
BOOL DBMachineHasBluetoothLE(NSString *machine) {
  for (NSString *prefix in @[ @"iPad", @"iPhone", @"iPod" ]) {
    if (![machine hasPrefix:prefix]) continue;
    NSArray *parts = [[machine substringFromIndex:[prefix length]]
        componentsSeparatedByString:@","];
    if ([parts count] != 2) return NO;
    NSInteger major = [[parts objectAtIndex:0] integerValue];
    NSInteger minor = [[parts objectAtIndex:1] integerValue];
    if ([prefix isEqualToString:@"iPad"]) return major >= 3 || (major == 2 && minor >= 5);
    if ([prefix isEqualToString:@"iPhone"]) return major >= 4;
    return major >= 5;
  }
  return NO;
}

BOOL DBDeviceHasBluetoothLE(void) {
  return DBMachineHasBluetoothLE(DBDeviceMachine());
}
