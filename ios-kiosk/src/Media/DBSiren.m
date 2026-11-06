#import "DBSiren.h"
#import "../Core/DBBootConfig.h"
#import <math.h>

void DBH264Dbg(NSString *fmt, ...);

@implementation DBSiren {
  AVAudioPlayer *_player;
  AVAudioPlayer *_chimePlayer;
  dispatch_queue_t _chimeQueue;
  NSUInteger _generation;
}

- (id)init {
  self = [super init];
  if (self) _chimeQueue = dispatch_queue_create("doorbell.chime.prepare", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (void)dealloc {
  AVAudioPlayer *effect = _player;
  AVAudioPlayer *chime = _chimePlayer;
  if ([NSThread isMainThread]) [effect stop];
  else dispatch_async(dispatch_get_main_queue(), ^{ [effect stop]; });
  dispatch_async(_chimeQueue, ^{ [chime stop]; });
}

- (void)swapPlayer:(AVAudioPlayer *)p {
  @synchronized(self) { _generation++; }
  dispatch_async(_chimeQueue, ^{ [self->_chimePlayer stop]; self->_chimePlayer = nil; });
  [_player stop];
  _player = p;
}

- (BOOL)playAssetPath:(NSString *)path {
  if ([path length] == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  AVAudioPlayer *p =
      [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:NULL];
  if (p == nil) return NO;
  [self swapPlayer:p];
  p.numberOfLoops = 0;
  return [p play];
}

+ (NSString *)fileNameForPreset:(NSString *)value {
  if ([value isEqualToString:@"outdoor_call_alert"]) return @"outdoor_call_alert.mp3";
  if ([value isEqualToString:@"button_click"]) return @"button_click.mp3";
  if ([value isEqualToString:@"school_chime"])
    return @"\u5b66\u6821\u306e\u30c1\u30e3\u30a4\u30e0.mp3";
  if ([value isEqualToString:@"indoor_update"]) return @"indoor_update.mp3";
  if ([value isEqualToString:@"title_display"]) return @"title_display.mp3";
  return nil;
}

- (BOOL)playConfiguredSound:(NSString *)value loop:(BOOL)loop {
  if (![value isKindOfClass:[NSString class]] || [value length] == 0) return NO;
  NSString *path = nil;
  if ([value hasPrefix:@"asset:"] && [value length] == 70) {
    path = [[[DBBootConfig dataDir] stringByAppendingPathComponent:@"assets"]
        stringByAppendingPathComponent:[value substringFromIndex:6]];
  } else {
    NSString *name = [[self class] fileNameForPreset:value];
    if (name) path = [[NSBundle mainBundle] pathForResource:[name stringByDeletingPathExtension]
                                                     ofType:[name pathExtension]];
  }
  if ([path length] == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
  AVAudioPlayer *p =
      [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:NULL];
  if (!p) return NO;
  [self swapPlayer:p];
  p.numberOfLoops = loop ? -1 : 0;
  return [p play];
}

- (void)playChimeSound:(NSString *)sound assetPath:(NSString *)path {
  NSUInteger generation;
  @synchronized(self) { generation = ++_generation; }
  [_player stop]; _player = nil;
  NSString *asset = [path copy];
  NSString *preset = [sound copy];
  __weak DBSiren *weakSelf = self;
  // mediaserverd can block both preparation and play. This queue exclusively
  // owns chime players; short generation checks order UI cancellation/replacement.
  dispatch_async(_chimeQueue, ^{
    DBSiren *owner = weakSelf;
    if (!owner) return;
    @synchronized(owner) { if (owner->_generation != generation) return; }
    [owner->_chimePlayer stop]; owner->_chimePlayer = nil;
    owner = nil;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    AVAudioPlayer *player = nil;
    if ([asset length] && [[NSFileManager defaultManager] fileExistsAtPath:asset])
      player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:asset] error:NULL];
    if (!player) {
      NSString *resource = nil;
      if ([preset hasPrefix:@"asset:"] && [preset length] == 70)
        resource = [[[DBBootConfig dataDir] stringByAppendingPathComponent:@"assets"]
            stringByAppendingPathComponent:[preset substringFromIndex:6]];
      else {
        NSString *name = [DBSiren fileNameForPreset:preset];
        if (name) resource = [[NSBundle mainBundle] pathForResource:[name stringByDeletingPathExtension]
                                                            ofType:[name pathExtension]];
      }
      if ([resource length]) player = [[AVAudioPlayer alloc] initWithContentsOfURL:
          [NSURL fileURLWithPath:resource] error:NULL];
    }
    if (!player || ![player prepareToPlay]) {
      player = [[AVAudioPlayer alloc] initWithData:[DBSiren chimeWav:preset] error:NULL];
      [player prepareToPlay];
    }
    player.numberOfLoops = 0;
    player.volume = 1.0f;
    DBH264Dbg(@"[call-startup] chime_prepared_ms=%lld",
        (long long)((CFAbsoluteTimeGetCurrent() - started) * 1000.0));
    owner = weakSelf;
    if (!owner || !player) return;
    @synchronized(owner) { if (owner->_generation != generation) return; }
    owner->_chimePlayer = player;
    CFAbsoluteTime playAt = CFAbsoluteTimeGetCurrent();
    [player play];
    DBH264Dbg(@"[call-startup] chime_play_ms=%lld", (long long)((CFAbsoluteTimeGetCurrent() - playAt) * 1000.0));
    BOOL cancelled;
    @synchronized(owner) { cancelled = owner->_generation != generation; }
    if (cancelled) { [player stop]; owner->_chimePlayer = nil; }
  });
}

- (void)startSiren:(NSString *)customPath volume:(NSInteger)volume {
  float vol = (float)MAX(0, MIN(100, volume)) / 100.0f;
  if ([customPath length] > 0 &&
      [[NSFileManager defaultManager] fileExistsAtPath:customPath]) {
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:customPath]
                                                              error:NULL];
    if (p) {
      [self swapPlayer:p];
      p.numberOfLoops = -1;
      p.volume = vol;
      if ([p play]) return;
    }
  }
  AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:[[self class] sirenWav] error:NULL];
  if (p == nil) return;
  [self swapPlayer:p];
  p.numberOfLoops = -1;
  p.volume = vol;
  [p play];
}

- (void)stop {
  @synchronized(self) { _generation++; }
  dispatch_async(_chimeQueue, ^{ [self->_chimePlayer stop]; self->_chimePlayer = nil; });
  [_player stop];
  _player = nil;
}


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
    double freq = ((i / (rate / 2)) % 2 == 0) ? 880.0 : 660.0;
    double env = MIN(1.0, (double)MIN(i, n - i) / ((double)rate * 0.02));
    short s = (short)(sin(2 * M_PI * freq * t) * 0.6 * (double)SHRT_MAX * env);
    uint16_t x = CFSwapInt16HostToLittle((uint16_t)s);
    [d appendBytes:&x length:2];
  }
  return d;
}


+ (NSData *)chimeWav:(NSString *)sound {
  const int rate = 22050;
  double seconds = [sound isEqualToString:@"classic"] ? 2.0 : 1.35;
  const int n = (int)(rate * seconds);
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
  [d appendBytes:"RIFF" length:4]; le32(36 + dataLen);
  [d appendBytes:"WAVEfmt " length:8]; le32(16); le16(1); le16(1);
  le32(rate); le32(rate * 2); le16(2); le16(16);
  [d appendBytes:"data" length:4]; le32(dataLen);
  for (int i = 0; i < n; i++) {
    double t = (double)i / rate;
    double freq = 0.0;
    if ([sound isEqualToString:@"classic"]) {
      if (t < 0.55) freq = 659.25;
      else if (t >= 0.72 && t < 1.27) freq = 523.25;
      else if (t >= 1.42) freq = 783.99;
    } else if ([sound isEqualToString:@"ding2"]) {
      if (t < 0.38) freq = 659.25;
      else if (t >= 0.58 && t < 1.15) freq = 987.77;
    } else {
      if (t < 0.42) freq = 880.0;
      else if (t >= 0.50 && t < 1.20) freq = 1174.66;
    }
    double env = freq == 0.0 ? 0.0 : MIN(1.0, MIN(t, seconds - t) / 0.025);
    short sample = (short)(sin(2 * M_PI * freq * t) * 0.62 * SHRT_MAX * env);
    uint16_t x = CFSwapInt16HostToLittle((uint16_t)sample);
    [d appendBytes:&x length:2];
  }
  return d;
}

@end
