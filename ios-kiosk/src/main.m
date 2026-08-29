#import <UIKit/UIKit.h>
#import "DBAppDelegate.h"

// ARC 版エントリポイント (ios-legacy の MRC pool 管理は不要)。
int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([DBAppDelegate class]));
  }
}
