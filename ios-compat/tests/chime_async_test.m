#import <Foundation/Foundation.h>
#import "DBSiren.h"

static NSUInteger plays;
static NSUInteger preparations;
static BOOL active;
static NSUInteger PlayCount(void) { @synchronized([AVAudioPlayer class]) { return plays; } }

void DBH264Dbg(NSString *format, ...) { (void)format; }
@implementation AVAudioPlayer
- (id)initWithData:(NSData *)data error:(NSError **)error {
  (void)data; (void)error; return [super init];
}
- (id)initWithContentsOfURL:(NSURL *)url error:(NSError **)error {
  (void)url; (void)error; return [super init];
}
- (BOOL)prepareToPlay {
  @synchronized([AVAudioPlayer class]) { preparations++; }
  [NSThread sleepForTimeInterval:0.15];
  return YES;
}
- (BOOL)play {
  NSCAssert(![NSThread isMainThread], @"Chime playback must not block the UI thread");
  [NSThread sleepForTimeInterval:0.15];
  @synchronized([AVAudioPlayer class]) { plays++; active = YES; }
  return YES;
}
- (void)stop { @synchronized([AVAudioPlayer class]) { active = NO; } }
@end

static void Pump(double seconds) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([deadline timeIntervalSinceNow] > 0)
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static void Require(BOOL condition, NSString *message) {
  if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
int main(void) {
  @autoreleasepool {
    DBSiren *siren = [[DBSiren alloc] init];
    CFAbsoluteTime at = CFAbsoluteTimeGetCurrent();
    [siren playChimeSound:@"ding1" assetPath:nil];
    Require(CFAbsoluteTimeGetCurrent() - at < 0.05, @"Chime preparation must not block rendering");
    Pump(0.05);
    @synchronized([AVAudioPlayer class]) { Require(preparations > 0, @"Preparation must start off-thread"); }
    [siren stop];
    Pump(0.25);
    Require(PlayCount() == 0, @"Closing a call must cancel a preparing chime");
    [siren playChimeSound:@"ding1" assetPath:nil];
    Pump(0.03);
    [siren playChimeSound:@"ding2" assetPath:nil];
    Pump(0.7);
    Require(PlayCount() == 1, @"A superseded chime must not play after its replacement");
    [siren stop]; Pump(0.1);
    @synchronized([AVAudioPlayer class]) { Require(!active, @"Cancellation must leave no player running"); }
    NSLog(@"PASS: background chime preparation, cancellation, and replacement ordering");
  }
  return 0;
}
