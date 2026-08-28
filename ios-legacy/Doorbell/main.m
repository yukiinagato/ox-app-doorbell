#import <UIKit/UIKit.h>
#import "DBAppDelegate.h"

int main(int argc, char *argv[]) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  int rc = UIApplicationMain(argc, argv, nil, NSStringFromClass([DBAppDelegate class]));
  [pool release];
  return rc;
}
