#import "DBRTPH264Depacketizer.h"

static const NSUInteger kDBRTPMaxPacketBytes = 32 * 1024;
static const NSUInteger kDBRTPMaxNALBytes = 1024 * 1024;
static const NSUInteger kDBRTPMaxAccessUnitBytes = 2 * 1024 * 1024;
static const NSUInteger kDBRTPMaxNALsPerAccessUnit = 128;

static const uint8_t kDBAnnexBStartCode[] = {0, 0, 0, 1};

@implementation DBRTPH264Depacketizer {
  DBRTPH264AccessUnitHandler _handler;
  NSMutableData *_accessUnit;
  NSMutableData *_fragmentedNAL;
  NSData *_sps;
  NSData *_pps;
  BOOL _haveSequence;
  uint16_t _expectedSequence;
  BOOL _haveTimestamp;
  uint32_t _timestamp;
  BOOL _accessUnitHasIDR;
  NSUInteger _nalCount;
  BOOL _waitingForIDR;
  NSUInteger _malformedPacketCount;
}

@synthesize waitingForIDR = _waitingForIDR;
@synthesize malformedPacketCount = _malformedPacketCount;

- (id)initWithAccessUnitHandler:(DBRTPH264AccessUnitHandler)handler {
  self = [super init];
  if (self) {
    _handler = [handler copy];
    _accessUnit = [[NSMutableData alloc] init];
    _waitingForIDR = YES;
  }
  return self;
}

- (BOOL)validParameterSet:(NSData *)data type:(uint8_t)type {
  if ([data length] < 2 || [data length] > kDBRTPMaxNALBytes) return NO;
  const uint8_t *bytes = [data bytes];
  if ((bytes[0] & 0x1f) != type) return NO;
  // The configured stream contract is H.264 Baseline. profile_idc is the
  // second byte of an SPS NAL after its one-byte NAL header.
  if (type == 7 && bytes[1] != 66) return NO;
  return YES;
}

- (void)seedSPS:(NSData *)sps pps:(NSData *)pps {
  if ([self validParameterSet:sps type:7]) _sps = [sps copy];
  if ([self validParameterSet:pps type:8]) _pps = [pps copy];
}

- (void)clearAccessUnit {
  [_accessUnit setLength:0];
  _fragmentedNAL = nil;
  _haveTimestamp = NO;
  _accessUnitHasIDR = NO;
  _nalCount = 0;
}

- (void)markTransportLoss {
  [self clearAccessUnit];
  _waitingForIDR = YES;
}

- (void)reset {
  [self markTransportLoss];
  _haveSequence = NO;
  _expectedSequence = 0;
  _malformedPacketCount = 0;
}

- (BOOL)rejectPacket {
  _malformedPacketCount++;
  [self markTransportLoss];
  return NO;
}

- (BOOL)appendNAL:(NSData *)nal {
  if ([nal length] == 0 || [nal length] > kDBRTPMaxNALBytes) return NO;
  const uint8_t *bytes = [nal bytes];
  uint8_t type = bytes[0] & 0x1f;
  if (type == 7) {
    if (![self validParameterSet:nal type:7]) return NO;
    _sps = [nal copy];
    return YES;
  }
  if (type == 8) {
    if (![self validParameterSet:nal type:8]) return NO;
    _pps = [nal copy];
    return YES;
  }
  if (type == 0 || type >= 24) return NO;
  if (_nalCount >= kDBRTPMaxNALsPerAccessUnit ||
      [_accessUnit length] + sizeof(kDBAnnexBStartCode) + [nal length] >
          kDBRTPMaxAccessUnitBytes)
    return NO;
  [_accessUnit appendBytes:kDBAnnexBStartCode length:sizeof(kDBAnnexBStartCode)];
  [_accessUnit appendData:nal];
  _nalCount++;
  if (type == 5) _accessUnitHasIDR = YES;
  return YES;
}

- (void)finishAccessUnit {
  if ([_accessUnit length] == 0) {
    [self clearAccessUnit];
    return;
  }
  if (_waitingForIDR && !_accessUnitHasIDR) {
    [self clearAccessUnit];
    return;
  }
  NSMutableData *output = _accessUnit;
  if (_accessUnitHasIDR) {
    if (!_sps || !_pps) {
      [self clearAccessUnit];
      _waitingForIDR = YES;
      return;
    }
    NSUInteger required = 2 * sizeof(kDBAnnexBStartCode) + [_sps length] +
                          [_pps length] + [_accessUnit length];
    if (required > kDBRTPMaxAccessUnitBytes) {
      [self clearAccessUnit];
      _waitingForIDR = YES;
      return;
    }
    output = [NSMutableData dataWithCapacity:required];
    [output appendBytes:kDBAnnexBStartCode length:sizeof(kDBAnnexBStartCode)];
    [output appendData:_sps];
    [output appendBytes:kDBAnnexBStartCode length:sizeof(kDBAnnexBStartCode)];
    [output appendData:_pps];
    [output appendData:_accessUnit];
  }
  NSData *immutable = [output copy];
  BOOL keyframe = _accessUnitHasIDR;
  uint32_t timestamp = _timestamp;
  [self clearAccessUnit];
  if (keyframe) _waitingForIDR = NO;
  if (_handler) _handler(immutable, keyframe, timestamp);
}

- (BOOL)consumeSingleNAL:(const uint8_t *)payload length:(NSUInteger)length {
  return [self appendNAL:[NSData dataWithBytes:payload length:length]];
}

- (BOOL)consumeSTAPA:(const uint8_t *)payload length:(NSUInteger)length {
  if (length < 4) return NO;
  NSUInteger offset = 1;
  NSMutableArray *nals = [NSMutableArray array];
  NSUInteger total = 0;
  while (offset < length) {
    if (length - offset < 2) return NO;
    NSUInteger nalLength = ((NSUInteger)payload[offset] << 8) | payload[offset + 1];
    offset += 2;
    if (nalLength == 0 || nalLength > kDBRTPMaxNALBytes || nalLength > length - offset)
      return NO;
    uint8_t type = payload[offset] & 0x1f;
    if (type == 0 || type >= 24) return NO;
    total += nalLength + sizeof(kDBAnnexBStartCode);
    if (total > kDBRTPMaxAccessUnitBytes || [nals count] >= kDBRTPMaxNALsPerAccessUnit)
      return NO;
    [nals addObject:[NSData dataWithBytes:payload + offset length:nalLength]];
    offset += nalLength;
  }
  for (NSData *nal in nals)
    if (![self appendNAL:nal]) return NO;
  return YES;
}

- (BOOL)consumeFUA:(const uint8_t *)payload length:(NSUInteger)length {
  if (length < 3) return NO;
  uint8_t indicator = payload[0];
  uint8_t header = payload[1];
  BOOL start = (header & 0x80) != 0;
  BOOL end = (header & 0x40) != 0;
  uint8_t type = header & 0x1f;
  if ((header & 0x20) != 0 || type == 0 || type >= 24 || (start && end)) return NO;
  if (start) {
    if (_fragmentedNAL != nil) return NO;
    uint8_t reconstructed = (indicator & 0xe0) | type;
    _fragmentedNAL = [NSMutableData dataWithCapacity:length];
    [_fragmentedNAL appendBytes:&reconstructed length:1];
  } else if (_fragmentedNAL == nil) {
    return NO;
  }
  NSUInteger fragmentLength = length - 2;
  if ([_fragmentedNAL length] + fragmentLength > kDBRTPMaxNALBytes) return NO;
  [_fragmentedNAL appendBytes:payload + 2 length:fragmentLength];
  if (end) {
    NSData *nal = [_fragmentedNAL copy];
    _fragmentedNAL = nil;
    return [self appendNAL:nal];
  }
  return YES;
}

- (BOOL)consumeRTPPacket:(NSData *)packet expectedPayloadType:(uint8_t)payloadType {
  NSUInteger length = [packet length];
  if (length < 12 || length > kDBRTPMaxPacketBytes) return [self rejectPacket];
  const uint8_t *bytes = [packet bytes];
  if ((bytes[0] >> 6) != 2) return [self rejectPacket];
  BOOL padding = (bytes[0] & 0x20) != 0;
  BOOL extension = (bytes[0] & 0x10) != 0;
  NSUInteger csrcCount = bytes[0] & 0x0f;
  uint8_t actualPayloadType = bytes[1] & 0x7f;
  BOOL marker = (bytes[1] & 0x80) != 0;
  if (actualPayloadType != payloadType) return YES;

  NSUInteger offset = 12 + csrcCount * 4;
  if (offset > length) return [self rejectPacket];
  if (extension) {
    if (length - offset < 4) return [self rejectPacket];
    NSUInteger extensionWords = ((NSUInteger)bytes[offset + 2] << 8) | bytes[offset + 3];
    NSUInteger extensionBytes = 4 + extensionWords * 4;
    if (extensionBytes > length - offset) return [self rejectPacket];
    offset += extensionBytes;
  }
  NSUInteger payloadLength = length - offset;
  if (padding) {
    if (payloadLength == 0) return [self rejectPacket];
    NSUInteger paddingLength = bytes[length - 1];
    if (paddingLength == 0 || paddingLength > payloadLength) return [self rejectPacket];
    payloadLength -= paddingLength;
  }
  if (payloadLength == 0) return [self rejectPacket];

  uint16_t sequence = ((uint16_t)bytes[2] << 8) | bytes[3];
  uint32_t timestamp = ((uint32_t)bytes[4] << 24) | ((uint32_t)bytes[5] << 16) |
                       ((uint32_t)bytes[6] << 8) | bytes[7];
  BOOL sequenceLoss = _haveSequence && sequence != _expectedSequence;
  _haveSequence = YES;
  _expectedSequence = (uint16_t)(sequence + 1);
  if (sequenceLoss) [self markTransportLoss];
  if (_haveTimestamp && timestamp != _timestamp &&
      ([_accessUnit length] > 0 || _fragmentedNAL != nil))
    [self markTransportLoss];
  if (!_haveTimestamp) {
    _timestamp = timestamp;
    _haveTimestamp = YES;
  }

  const uint8_t *payload = bytes + offset;
  uint8_t nalType = payload[0] & 0x1f;
  BOOL valid = NO;
  if (nalType >= 1 && nalType <= 23)
    valid = [self consumeSingleNAL:payload length:payloadLength];
  else if (nalType == 24)
    valid = [self consumeSTAPA:payload length:payloadLength];
  else if (nalType == 28)
    valid = [self consumeFUA:payload length:payloadLength];
  if (!valid) return [self rejectPacket];
  if (marker) {
    if (_fragmentedNAL != nil) return [self rejectPacket];
    [self finishAccessUnit];
  }
  return YES;
}

@end
