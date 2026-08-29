#import "DBSirenPlayer.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>

@implementation DBSirenPlayer {
  AVAudioPlayer *_player;
}

- (void)dealloc {
  [self stop];
  [super dealloc];
}

- (void)swapPlayer:(AVAudioPlayer *)p {
  [p retain];
  [_player stop];
  [_player release];
  _player = p;
}

- (BOOL)playAssetPath:(NSString *)path {
  if ([path length] == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  NSError *err = nil;
  AVAudioPlayer *p =
      [[[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err] autorelease];
  if (p == nil) return NO;
  [self swapPlayer:p];
  p.numberOfLoops = 0;
  return [p play];
}

- (BOOL)playConfigured:(NSString *)value dataDir:(NSString *)dataDir loop:(BOOL)loop {
  if ([value length] == 0) return NO;
  NSString *path = nil;
  if ([value hasPrefix:@"asset:"] && [value length] == 70) {
    path = [[dataDir stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:[value substringFromIndex:6]];
  } else {
    NSDictionary *files = [NSDictionary dictionaryWithObjectsAndKeys:
        @"outdoor_call_alert.mp3", @"outdoor_call_alert",
        @"button_click.mp3", @"button_click",
        @"学校のチャイム.mp3", @"school_chime",
        @"indoor_update.mp3", @"indoor_update",
        @"title_display.mp3", @"title_display", nil];
    NSString *filename = [files objectForKey:value];
    if (filename) path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:filename];
  }
  if ([path length] == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  AVAudioPlayer *p = [[[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                             error:NULL] autorelease];
  if (!p) return NO;
  [self swapPlayer:p];
  p.numberOfLoops = loop ? -1 : 0;
  return [p play];
}

- (void)startSiren:(NSString *)customPath volume:(NSInteger)volume {
  float vol = (float)MAX(0, MIN(100, volume)) / 100.0f;
  if ([customPath length] > 0 && [[NSFileManager defaultManager] fileExistsAtPath:customPath]) {
    AVAudioPlayer *p = [[[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:customPath]
                                                              error:NULL] autorelease];
    if (p) {
      [self swapPlayer:p];
      p.numberOfLoops = -1;
      p.volume = vol;
      if ([p play]) return;
    }
  }
  AVAudioPlayer *p = [[[AVAudioPlayer alloc] initWithData:[[self class] sirenWav] error:NULL] autorelease];
  if (p == nil) return;
  [self swapPlayer:p];
  p.numberOfLoops = -1;
  p.volume = vol;
  [p play];
}

- (void)stop {
  [_player stop];
  [_player release];
  _player = nil;
}

// 880/660Hz 交互 2 秒の警報音 (22.05kHz 16bit mono PCM WAV)。
+ (NSData *)sirenWav {
  const int rate = 22050;
  const int seconds = 2;
  const int n = rate * seconds;
  const int dataLen = n * 2;
  NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataLen];
  void (^le32)(uint32_t) = ^(uint32_t v) {
    uint32_t x = CFSwapInt32HostToLittle(v);
    [d appendBytes:&x length:4];
  };
  void (^le16)(uint16_t) = ^(uint16_t v) {
    uint16_t x = CFSwapInt16HostToLittle(v);
    [d appendBytes:&x length:2];
  };
  [d appendBytes:"RIFF" length:4];
  le32(36 + dataLen);
  [d appendBytes:"WAVE" length:4];
  [d appendBytes:"fmt " length:4];
  le32(16);
  le16(1);          // PCM
  le16(1);          // mono
  le32(rate);
  le32(rate * 2);   // byte rate
  le16(2);          // block align
  le16(16);         // bits
  [d appendBytes:"data" length:4];
  le32(dataLen);
  for (int i = 0; i < n; i++) {
    double t = (double)i / (double)rate;
    double freq = ((i / (rate / 2)) % 2 == 0) ? 880.0 : 660.0;  // 0.5 秒毎に交互
    double env = MIN(1.0, (double)MIN(i, n - i) / ((double)rate * 0.02));  // クリック防止
    short s = (short)(sin(2 * M_PI * freq * t) * 0.6 * (double)SHRT_MAX * env);
    uint16_t x = CFSwapInt16HostToLittle((uint16_t)s);
    [d appendBytes:&x length:2];
  }
  return d;
}

@end
