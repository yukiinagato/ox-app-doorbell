#import "DBAudioIO.h"
#import <AudioUnit/AudioUnit.h>


#define DB_RING_CAP 16384
typedef struct {
  short buf[DB_RING_CAP];
  volatile uint32_t head;
  volatile uint32_t tail;
} DBRing;

static void DBRingReset(DBRing *r) { r->head = r->tail = 0; }

static int DBRingWrite(DBRing *r, const short *src, int n) {
  uint32_t tail = r->tail;
  uint32_t head = r->head;
  uint32_t space = DB_RING_CAP - (uint32_t)(tail - head);
  int wrote = 0;
  while ((uint32_t)wrote < (uint32_t)n && (uint32_t)wrote < space) {
    r->buf[(tail + wrote) & (DB_RING_CAP - 1)] = src[wrote];
    wrote++;
  }
  r->tail = tail + wrote;
  return wrote;
}

static int DBRingRead(DBRing *r, short *dst, int n) {
  uint32_t head = r->head;
  uint32_t tail = r->tail;
  uint32_t used = (uint32_t)(tail - head);
  int got = 0;
  while ((uint32_t)got < (uint32_t)n && (uint32_t)got < used) {
    dst[got] = r->buf[(head + got) & (DB_RING_CAP - 1)];
    got++;
  }
  r->head = head + got;
  return got;
}

@implementation DBAudioIO {
  AudioUnit _unit;
  BOOL _running;
  DBRing _rx;
  DBRing _tx;
  AudioBufferList *_inList;
}

@synthesize micEnabled = _micEnabled;


static OSStatus DBRenderCb(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                           const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                           UInt32 inNumberFrames, AudioBufferList *ioData) {
  (void)ioActionFlags;
  (void)inTimeStamp;
  (void)inBusNumber;
  DBAudioIO *self = (__bridge DBAudioIO *)inRefCon;
  for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
    short *out = (short *)ioData->mBuffers[b].mData;
    int frames = (int)inNumberFrames;
    int got = DBRingRead(&self->_rx, out, frames);
    for (int i = got; i < frames; i++) out[i] = 0;
  }
  return noErr;
}


static OSStatus DBInputCb(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                          const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                          UInt32 inNumberFrames, AudioBufferList *ioData) {
  (void)ioData;
  DBAudioIO *self = (__bridge DBAudioIO *)inRefCon;
  AudioBufferList *list = self->_inList;
  list->mNumberBuffers = 1;
  list->mBuffers[0].mNumberChannels = 1;
  list->mBuffers[0].mDataByteSize = inNumberFrames * sizeof(short);
  OSStatus st = AudioUnitRender(self->_unit, ioActionFlags, inTimeStamp, inBusNumber,
                                inNumberFrames, list);
  if (st == noErr) {
    DBRingWrite(&self->_tx, (const short *)list->mBuffers[0].mData, (int)inNumberFrames);
  }
  return st;
}
- (id)init {
  self = [super init];
  if (self) {
    DBRingReset(&_rx);
    DBRingReset(&_tx);
    _inList = (AudioBufferList *)calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    _inList->mNumberBuffers = 1;
    _inList->mBuffers[0].mData = malloc(DB_RING_CAP * sizeof(short));
  }
  return self;
}

- (void)dealloc {
  [self stop];
  if (_inList) {
    free(_inList->mBuffers[0].mData);
    free(_inList);
  }
}

static AudioStreamBasicDescription DBFormat8k(void) {
  AudioStreamBasicDescription f;
  memset(&f, 0, sizeof(f));
  f.mSampleRate = 8000.0;
  f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
  f.mFramesPerPacket = 1;
  f.mChannelsPerFrame = 1;
  f.mBitsPerChannel = 16;
  f.mBytesPerFrame = 2;
  f.mBytesPerPacket = 2;
  return f;
}

- (BOOL)start {
  if (_running) return YES;

  // Listen-only sessions use MediaPlayback so old iPads cannot fall back to the
  // effectively inaudible receiver route when a PlayAndRecord override fails.
  AudioSessionInitialize(NULL, NULL, NULL, NULL);
  UInt32 category = _micEnabled ? kAudioSessionCategory_PlayAndRecord
                                : kAudioSessionCategory_MediaPlayback;
  OSStatus sessionStatus =
      AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
  if (_micEnabled) {
    UInt32 toSpeaker = 1;
    OSStatus routeStatus = AudioSessionSetProperty(
        kAudioSessionProperty_OverrideCategoryDefaultToSpeaker, sizeof(toSpeaker), &toSpeaker);
    if (routeStatus != noErr) NSLog(@"[doorbell] audio: speaker route failed %ld", (long)routeStatus);
  }
  OSStatus activeStatus = AudioSessionSetActive(true);
  if (sessionStatus != noErr || activeStatus != noErr) {
    NSLog(@"[doorbell] audio: session start failed category=%ld active=%ld",
          (long)sessionStatus, (long)activeStatus);
    return NO;
  }

  AudioComponentDescription desc;
  memset(&desc, 0, sizeof(desc));
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_RemoteIO;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  AudioComponent comp = AudioComponentFindNext(NULL, &desc);
  if (comp == NULL) { AudioSessionSetActive(false); return NO; }
  if (AudioComponentInstanceNew(comp, &_unit) != noErr) {
    AudioSessionSetActive(false);
    return NO;
  }

  const AudioUnitElement outputBus = 0;
  const AudioUnitElement inputBus = 1;

  UInt32 enable = 1;
  AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                       outputBus, &enable, sizeof(enable));
  UInt32 enableIn = _micEnabled ? 1 : 0;
  AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                       inputBus, &enableIn, sizeof(enableIn));

  AudioStreamBasicDescription fmt = DBFormat8k();
  AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                       outputBus, &fmt, sizeof(fmt));
  if (_micEnabled) {
    AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                         inputBus, &fmt, sizeof(fmt));
  }

  AURenderCallbackStruct render;
  render.inputProc = DBRenderCb;
  render.inputProcRefCon = (__bridge void *)self;
  AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                       outputBus, &render, sizeof(render));

  if (_micEnabled) {
    AURenderCallbackStruct input;
    input.inputProc = DBInputCb;
    input.inputProcRefCon = (__bridge void *)self;
    AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback,
                         kAudioUnitScope_Global, inputBus, &input, sizeof(input));
  }

  if (AudioUnitInitialize(_unit) != noErr) {
    AudioComponentInstanceDispose(_unit);
    _unit = NULL;
    AudioSessionSetActive(false);
    return NO;
  }
  if (AudioOutputUnitStart(_unit) != noErr) {
    AudioUnitUninitialize(_unit);
    AudioComponentInstanceDispose(_unit);
    _unit = NULL;
    AudioSessionSetActive(false);
    return NO;
  }
  _running = YES;
  return YES;
}

- (void)stop {
  if (_unit) {
    AudioOutputUnitStop(_unit);
    AudioUnitUninitialize(_unit);
    AudioComponentInstanceDispose(_unit);
    _unit = NULL;
  }
  if (_running) {
    AudioSessionSetActive(false);
    _running = NO;
  }
  DBRingReset(&_rx);
  DBRingReset(&_tx);
}

- (void)enqueueRx:(const short *)pcm count:(int)n {
  if (n > 0) DBRingWrite(&_rx, pcm, n);
}

- (int)dequeueTx:(short *)pcm max:(int)n {
  return DBRingRead(&_tx, pcm, n);
}

@end
