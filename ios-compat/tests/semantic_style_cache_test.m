#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "DBSemanticStyle.h"
@implementation UIColor { CGColorRef _color; }
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  UIColor *color = [[UIColor alloc] init];
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGFloat components[] = {r,g,b,a};
  color->_color = CGColorCreate(space, components); CGColorSpaceRelease(space); return color;
}
+ (UIColor *)clearColor { return [self colorWithRed:0 green:0 blue:0 alpha:0]; }
- (CGColorRef)CGColor { return _color; }
- (void)dealloc { if (_color) CGColorRelease(_color); }
@end
@implementation UIFont
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size { (void)size; return [[UIFont alloc] init]; }
@end
@implementation UILabel @end
@implementation UIButton
- (void)setTitleColor:(UIColor *)color forState:(NSUInteger)state { (void)color; (void)state; }
@end
static NSUserDefaults *suite;
static NSUInteger flushes;
static BOOL failFlush;
static id Defaults(id object, SEL selector) { (void)object; (void)selector; return suite; }
static BOOL Flush(id object, SEL selector) { (void)object; (void)selector; flushes++; return !failFlush; }
static void Require(BOOL condition, NSString *message) {
  if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static NSDictionary *Config(NSDictionary *style) {
  return @{ @"devices": @{ @"cache-test": @{ @"local": @{ @"ui": @{ @"elements": @{ @"ring.title":style } } } } } };
}
static NSDictionary *Resolve(NSDictionary *config) {
  return [DBSemanticStyle styleForConfig:config deviceID:@"cache-test" semanticID:@"ring.title"
      safetyCritical:NO baselineForeground:[UIColor colorWithRed:1 green:1 blue:1 alpha:1]
      baselineBackground:[UIColor colorWithRed:0 green:0 blue:0 alpha:1]
      baselineAccent:nil baselineBorder:nil];
}
int main(void) {
  @autoreleasepool {
    NSString *domain = [@"doorbell.style-cache-test." stringByAppendingString:[[NSUUID UUID] UUIDString]];
    suite = [[NSUserDefaults alloc] initWithSuiteName:domain];
    Method standard = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
    Method synchronize = class_getInstanceMethod([NSUserDefaults class], @selector(synchronize));
    IMP oldStandard = method_setImplementation(standard, (IMP)Defaults);
    IMP oldFlush = method_setImplementation(synchronize, (IMP)Flush);
    __block NSUInteger reports = 0;
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:
        DBSemanticStyleReportDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
      (void)note; reports++;
    }];
    Resolve(@{}); Resolve(@{});
    Require(reports == 1 && flushes == 0, @"Unchanged default styles must not flood runtime reports");
    NSDictionary *first = Config(@{ @"foreground":@"#FFFFFF", @"background":@"#000000" });
    Resolve(first);
    for (NSUInteger i=0; i<100; i++)
      Resolve(Config(@{ @"background":@"#000000", @"foreground":@"#FFFFFF" }));
    Require(flushes == 1 && reports == 2, @"Repeated drawing must reuse a confirmed persisted style");
    Resolve(Config(@{ @"foreground":@"#FFFF00", @"background":@"#000000" }));
    Require(flushes == 2 && reports == 3, @"Changed style values must persist and report even if result flags match");
    NSDictionary *changed = Config(@{ @"foreground":@"#FFFF00", @"background":@"#000000", @"font_scale":@1.2 });
    failFlush = YES; Resolve(changed); Resolve(changed);
    Require(flushes == 4, @"Failed persistence must retry instead of entering the reuse cache");
    NSDictionary *outcome = [[[DBSemanticStyle runtimeReport] objectForKey:@"elements"] objectForKey:@"ring.title"];
    Require(![[outcome objectForKey:@"lkg_persisted"] boolValue], @"A failed flush must not claim persistence");
    failFlush = NO; Resolve(changed);
    Require(flushes == 5, @"A later successful flush must recover persistence");
    [suite removeObjectForKey:@"ui.lkg.cache-test.ring.title"];
    Resolve(changed);
    Require(flushes == 6, @"Cleared stored data must be written again despite the in-process cache");
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    method_setImplementation(standard, oldStandard); method_setImplementation(synchronize, oldFlush);
    [suite removePersistentDomainForName:domain];
    NSLog(@"PASS: style redraw deduplication, changed values, failed writes, and cache invalidation");
  }
  return 0;
}
