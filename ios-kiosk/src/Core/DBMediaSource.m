#import "DBMediaSource.h"

#import "DBBootConfig.h"

@interface DBMediaSource ()
@property(nonatomic, readwrite, copy) NSString *kind;
@property(nonatomic, readwrite, copy) NSString *sourceRef;
@property(nonatomic, readwrite, copy) NSString *deviceID;
@property(nonatomic, readwrite, copy) NSString *mjpegURL;
@property(nonatomic, readwrite, copy) NSString *mp4URL;
@property(nonatomic, readwrite, copy) NSString *snapshotURL;
@property(nonatomic, readwrite, copy) NSString *h264URL;
@property(nonatomic, readwrite, copy) NSString *h264Transport;
@property(nonatomic, readwrite, copy) NSString *h264Profile;
@property(nonatomic, readwrite, copy) NSString *secretRef;
@property(nonatomic, readwrite, copy) NSString *videoMetaURL;
@property(nonatomic, readwrite) BOOL explicitlyUnavailable;
@property(nonatomic, readwrite) BOOL h264SourceAvailable;
@property(nonatomic, readwrite) BOOL requiresH264Ingest;
@property(nonatomic, readwrite, copy) NSString *degradedReason;
@end

@implementation DBMediaSource

+ (int)hexNibble:(uint8_t)value {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  if (value >= 'A' && value <= 'F') return value - 'A' + 10;
  return -1;
}

+ (NSString *)decodedQueryName:(NSString *)raw {
  NSData *encoded = [raw dataUsingEncoding:NSUTF8StringEncoding];
  const uint8_t *bytes = [encoded bytes];
  NSMutableData *decoded = [NSMutableData dataWithCapacity:[encoded length]];
  for (NSUInteger index = 0; index < [encoded length]; index++) {
    uint8_t value = bytes[index];
    if (value == '%' && index + 2 < [encoded length]) {
      int high = [self hexNibble:bytes[index + 1]];
      int low = [self hexNibble:bytes[index + 2]];
      if (high >= 0 && low >= 0) {
        value = (uint8_t)((high << 4) | low);
        index += 2;
      }
    } else if (value == '+') {
      value = ' ';
    }
    [decoded appendBytes:&value length:1];
  }
  NSString *name = [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
  return [name lowercaseString] ?: @"";
}

- (id)init {
  self = [super init];
  if (self) {
    _kind = @"none";
    _sourceRef = @"";
    _deviceID = @"";
    _mjpegURL = @"";
    _mp4URL = @"";
    _snapshotURL = @"";
    _h264URL = @"";
    _h264Transport = @"";
    _h264Profile = @"";
    _secretRef = @"";
    _videoMetaURL = @"";
    _degradedReason = @"";
  }
  return self;
}

- (BOOL)hasVideo {
  return !_explicitlyUnavailable && ([_mjpegURL length] > 0 || [_mp4URL length] > 0);
}

- (BOOL)hasPreview {
  return [self hasVideo] || (!_explicitlyUnavailable && [_snapshotURL length] > 0);
}

- (NSString *)preferredPreviewTransport {
  if (_explicitlyUnavailable) return @"none";
  if ([_mjpegURL length] > 0) return @"mjpeg";
  if ([_snapshotURL length] > 0) return @"snapshot";
  return @"none";
}

- (BOOL)supportsDirectJPEGPlayback {
  return !_explicitlyUnavailable &&
      ([_mjpegURL length] > 0 || [_snapshotURL length] > 0);
}

+ (NSString *)stringFrom:(NSDictionary *)d keys:(NSArray *)keys {
  if (![d isKindOfClass:[NSDictionary class]]) return nil;
  for (NSString *key in keys) {
    id value = [d objectForKey:key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0)
      return value;
  }
  return nil;
}

+ (BOOL)dict:(NSDictionary *)d explicitAvailability:(BOOL *)available {
  if (![d isKindOfClass:[NSDictionary class]]) return NO;
  id value = [d objectForKey:@"video_available"];
  if (![value isKindOfClass:[NSNumber class]]) value = [d objectForKey:@"available"];
  if (![value isKindOfClass:[NSNumber class]]) return NO;
  if (available) *available = [(NSNumber *)value boolValue];
  return YES;
}

+ (NSString *)peerHost:(NSDictionary *)peer {
  id addresses = [peer objectForKey:@"addrs"];
  if (![addresses isKindOfClass:[NSArray class]]) return nil;
  for (id value in (NSArray *)addresses) {
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) continue;
    NSString *raw = value;
    if ([raw hasPrefix:@"["]) {
      NSRange end = [raw rangeOfString:@"]"];
      if (end.location != NSNotFound && end.location > 1)
        return [raw substringWithRange:NSMakeRange(1, end.location - 1)];
    }
    NSArray *parts = [raw componentsSeparatedByString:@":"];
    return [parts count] == 2 ? [parts objectAtIndex:0] : raw;
  }
  return nil;
}

+ (NSString *)urlHost:(NSString *)host {
  if ([host length] == 0 || [host hasPrefix:@"["]) return host;
  return [host rangeOfString:@":"].location == NSNotFound
      ? host : [NSString stringWithFormat:@"[%@]", host];
}

+ (NSString *)safeURL:(NSString *)raw host:(NSString *)host port:(NSInteger)port
              schemes:(NSArray *)schemes {
  if ([raw length] == 0 || [raw length] > 4096) return @"";
  NSString *value = [raw stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([value hasPrefix:@"/"] && [host length] > 0) {
    NSString *urlHost = [self urlHost:host];
    value = [NSString stringWithFormat:@"http://%@:%ld%@", urlHost, (long)port, value];
  }
  NSURL *url = [NSURL URLWithString:value];
  NSString *scheme = [[url scheme] lowercaseString];
  if (![schemes containsObject:scheme] || [[url host] length] == 0) return @"";
  // Common config forbids userinfo URLs. Reject them again at the final sink so
  // a stale/legacy config cannot leak credentials into logs or HTTP requests.
  if ([[url user] length] > 0 || [[url password] length] > 0) return @"";
  if ([[url fragment] length] > 0) return @"";
  NSSet *sensitive = [NSSet setWithObjects:@"token", @"key", @"k", @"api_key",
      @"apikey", @"password", @"pass", @"passwd", @"secret", @"credential",
      @"auth", @"authorization", @"access_token", @"bearer", @"signature", @"sig", nil];
  for (NSString *component in [[url query] componentsSeparatedByCharactersInSet:
      [NSCharacterSet characterSetWithCharactersInString:@"&;"]]) {
    NSString *name = [[component componentsSeparatedByString:@"="] objectAtIndex:0];
    for (NSUInteger pass = 0; pass < 8; pass++) {
      NSString *decoded = [self decodedQueryName:name];
      if ([decoded isEqualToString:name]) break;
      name = decoded;
    }
    if ([name rangeOfString:@"%"].location != NSNotFound) return @"";
    if ([sensitive containsObject:name] || [name hasSuffix:@"_token"] ||
        [name hasSuffix:@"_secret"] || [name hasSuffix:@"_signature"]) return @"";
  }
  return [value copy];
}

+ (NSString *)safeSecretRef:(NSString *)value {
  if (![value isKindOfClass:[NSString class]] || ![value hasPrefix:@"secret:"] ||
      [value length] <= 7 || [value length] > 135)
    return @"";
  NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
  NSString *name = [value substringFromIndex:7];
  return [name rangeOfCharacterFromSet:invalid].location == NSNotFound ? value : @"";
}

+ (NSDictionary *)dictionary:(NSDictionary *)dictionary key:(NSString *)key {
  id value = [dictionary objectForKey:key];
  return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

+ (NSString *)deviceIDForPeer:(NSDictionary *)peer config:(NSDictionary *)config
                         door:(NSString *)door explicit:(NSString *)explicit {
  if ([explicit length] > 0) return explicit;
  NSString *peerID = [self stringFrom:peer keys:@[@"id", @"node_id"]];
  if ([peerID length] > 0) return peerID;
  NSDictionary *devices = [self dictionary:config key:@"devices"];
  for (NSString *identifier in devices) {
    NSDictionary *device = [self dictionary:devices key:identifier];
    if (![[self stringFrom:device keys:@[@"role"]] isEqualToString:@"door_station"])
      continue;
    if ([door length] > 0 && ![[self stringFrom:device keys:@[@"door"]] isEqualToString:door])
      continue;
    return identifier;
  }
  return @"";
}

+ (NSString *)sourceRefForDevice:(NSString *)deviceID config:(NSDictionary *)config {
  NSDictionary *devices = [self dictionary:config key:@"devices"];
  NSDictionary *device = [self dictionary:devices key:deviceID];
  NSDictionary *local = [self dictionary:device key:@"local"];
  NSDictionary *camera = [self dictionary:local key:@"camera"];
  return [self stringFrom:camera keys:@[@"source_ref"]] ?: @"";
}

+ (NSDictionary *)sourceDefinition:(NSString *)sourceRef config:(NSDictionary *)config {
  NSDictionary *sources = [self dictionary:config key:@"media_sources"];
  return [self dictionary:sources key:sourceRef];
}

+ (DBMediaSource *)sourceForPeer:(NSDictionary *)peer
                          config:(NSDictionary *)config
                            boot:(DBBootConfig *)boot
                            door:(NSString *)door
                        deviceID:(NSString *)deviceID {
  DBMediaSource *out = [[DBMediaSource alloc] init];
  NSString *host = [self peerHost:peer];
  NSInteger port = 47180;
  out.deviceID = [self deviceIDForPeer:peer config:config door:door explicit:deviceID];
  out.sourceRef = [self sourceRefForDevice:out.deviceID config:config];

  if ([out.sourceRef length] > 0) {
    NSDictionary *source = [self sourceDefinition:out.sourceRef config:config];
    NSInteger schemaVersion = [[source objectForKey:@"schema_version"] integerValue];
    NSString *kind = [self stringFrom:source keys:@[@"kind"]];
    if (![source isKindOfClass:[NSDictionary class]] || schemaVersion != 1 ||
        ![kind isEqualToString:@"ip_camera"]) {
      out.kind = @"none";
      out.explicitlyUnavailable = YES;
      out.degradedReason = @"invalid_source_definition";
      return out;
    }

    NSDictionary *streams = [self dictionary:source key:@"streams"];
    NSDictionary *h264 = [self dictionary:streams key:@"h264"];
    NSDictionary *mjpeg = [self dictionary:streams key:@"mjpeg"];
    NSDictionary *snapshot = [self dictionary:streams key:@"snapshot"];
    NSString *h264URL = [self safeURL:[self stringFrom:h264 keys:@[@"url"]]
                                    host:nil port:0 schemes:@[@"rtsp"]];
    NSString *transport = [self stringFrom:h264 keys:@[@"transport"]];
    NSString *profile = [self stringFrom:h264 keys:@[@"profile"]];
    BOOL validH264 = [h264 count] == 0 ||
        ([h264URL length] > 0 && [transport isEqualToString:@"tcp"] &&
         [profile isEqualToString:@"baseline"]);
    out.h264URL = validH264 ? h264URL : @"";
    out.h264Transport = validH264 && [h264 count] > 0 ? transport : @"";
    out.h264Profile = validH264 && [h264 count] > 0 ? profile : @"";
    id rawSecretRef = [source objectForKey:@"secret_ref"];
    out.secretRef = [self safeSecretRef:rawSecretRef];
    if (rawSecretRef != nil && [out.secretRef length] == 0) {
      out.kind = @"none";
      out.explicitlyUnavailable = YES;
      out.degradedReason = @"invalid_secret_ref";
      return out;
    }
    out.h264SourceAvailable = [h264 count] > 0 && validH264;
    out.requiresH264Ingest = out.h264SourceAvailable;
    out.mjpegURL = [self safeURL:[self stringFrom:mjpeg keys:@[@"url"]]
                             host:nil port:0 schemes:@[@"http", @"https"]];
    out.snapshotURL = [self safeURL:[self stringFrom:snapshot keys:@[@"url"]]
                                    host:nil port:0 schemes:@[@"http", @"https"]];
    out.kind = @"ip_camera";
    if (!validH264) {
      out.degradedReason = @"invalid_h264_stream";
    } else if (out.h264SourceAvailable && [out.degradedReason length] == 0) {
      // RTSP/TCP is an ingest source, never an fMP4 playback URL. Runtime stays
      // degraded until the source component forwards its first complete IDR.
      out.degradedReason = @"rtsp_ingest_pending";
    }
    if (![out hasPreview] && !out.h264SourceAvailable) {
      out.explicitlyUnavailable = YES;
      if ([out.degradedReason length] == 0) out.degradedReason = @"no_usable_stream";
    }
    return out;
  }

  BOOL available = YES;
  BOOL explicitAvailability = [self dict:peer explicitAvailability:&available];
  if (explicitAvailability && !available) {
    out.kind = @"none";
    out.explicitlyUnavailable = YES;
    return out;
  }

  BOOL localDoor = [boot.role isEqualToString:@"door_station"] &&
      ([door length] == 0 || [boot.door length] == 0 || [door isEqualToString:boot.door]);
  BOOL localOverride = localDoor &&
      ([boot.videoSource isEqualToString:@"ip_camera"] ||
       [boot.videoMjpegURL length] > 0 || [boot.videoMp4URL length] > 0 ||
       [boot.videoSnapshotURL length] > 0);
  if (localDoor && [boot.videoSource isEqualToString:@"none"]) {
    out.kind = @"none";
    out.explicitlyUnavailable = YES;
    return out;
  }

  NSString *mjpeg = nil;
  NSString *mp4 = nil;
  NSString *snapshot = nil;
  NSString *meta = nil;
  if (localOverride) {
    out.sourceRef = @"legacy_boot";
    if ([boot.videoMjpegURL length] > 0) mjpeg = boot.videoMjpegURL;
    if ([boot.videoMp4URL length] > 0) mp4 = boot.videoMp4URL;
    if ([boot.videoSnapshotURL length] > 0) snapshot = boot.videoSnapshotURL;
  }
  if ([mjpeg length] == 0)
    mjpeg = [self stringFrom:peer keys:@[@"stream_mjpeg", @"stream"]];
  if ([mp4 length] == 0)
    mp4 = [self stringFrom:peer keys:@[@"stream_mp4"]];
  if ([snapshot length] == 0)
    snapshot = [self stringFrom:peer keys:@[@"snapshot_url", @"snapshot"]];
  if ([meta length] == 0)
    meta = [self stringFrom:peer keys:@[@"video_meta_url"]];

  // Backward compatibility applies only to a peer whose role is known. A seed
  // address by itself is connectivity information, never proof of a camera or
  // a door-station role.
  BOOL knownDoorPeer = [[self stringFrom:peer keys:@[@"role"]] isEqualToString:@"door_station"];
  if ([mjpeg length] == 0 && knownDoorPeer && [host length] > 0)
    mjpeg = @"/stream.mjpeg";
  if ([mp4 length] == 0 && knownDoorPeer && [host length] > 0)
    mp4 = @"/stream.mp4";
  if ([snapshot length] == 0 && knownDoorPeer && [host length] > 0)
    snapshot = @"/snapshot.jpg";
  if ([meta length] == 0 && knownDoorPeer && !localOverride &&
      [host length] > 0)
    meta = @"/video-meta";

  out.mjpegURL = [self safeURL:mjpeg host:host port:port schemes:@[@"http", @"https"]];
  out.mp4URL = [self safeURL:mp4 host:host port:port schemes:@[@"http", @"https"]];
  out.snapshotURL = [self safeURL:snapshot host:host port:port schemes:@[@"http", @"https"]];
  out.videoMetaURL = [self safeURL:meta host:host port:port schemes:@[@"http", @"https"]];
  out.kind = localOverride ? @"ip_camera" :
      ([out hasPreview] ? @"node" : @"none");
  if (localOverride && [out.degradedReason length] == 0)
    out.degradedReason = @"legacy_boot_source";
  if (![out hasVideo] && explicitAvailability && !available) out.explicitlyUnavailable = YES;
  return out;
}

@end
