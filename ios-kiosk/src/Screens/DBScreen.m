#import "DBScreen.h"

@implementation DBScreen

- (NSString *)screenName {
  return @"screen";
}

- (void)onScreenWillAppear {
}

- (void)onScreenWillDisappear {
}

- (void)clearLabelBackgrounds:(UIView *)v {
  for (UIView *sub in v.subviews) {
    if ([sub isKindOfClass:[UILabel class]]) sub.backgroundColor = [UIColor clearColor];
    [self clearLabelBackgrounds:sub];
  }
}

@end
