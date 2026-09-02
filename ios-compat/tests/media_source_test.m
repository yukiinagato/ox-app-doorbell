#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "DBBootConfig.h"
#import "DBMediaSource.h"

static void require(BOOL condition, NSString *message) {
  if (!condition) {
    NSLog(@"FAIL: %@", message);
    exit(1);
  }
}

static BOOL classDeclaresClassSelector(Class cls, SEL selector) {
  unsigned int count = 0;
  Method *methods = class_copyMethodList(object_getClass(cls), &count);
  BOOL found = NO;
  for (unsigned int index = 0; index < count; ++index) {
    if (method_getName(methods[index]) == selector) {
      found = YES;
      break;
    }
  }
  free(methods);
  return found;
}

static DBBootConfig *doorBoot(void) {
  DBBootConfig *boot = [[DBBootConfig alloc] init];
  boot.role = @"door_station";
  boot.door = @"front";
  boot.videoSource = @"auto";
  return boot;
}

int main(void) {
  @autoreleasepool {
    require(!classDeclaresClassSelector([DBBootConfig class], @selector(load)),
            @"boot loader must not use the Objective-C pre-main +load hook");
    require(classDeclaresClassSelector([DBBootConfig class], @selector(loadConfiguration)),
            @"boot loader has an explicit non-runtime selector");
    require([DBBootConfig isValidDoor:@"door-a1"] &&
            ![DBBootConfig isValidDoor:@"-door"] &&
            ![DBBootConfig isValidDoor:@""],
            @"bootstrap door IDs start with an alphanumeric character");

    NSString *pairedJson = [DBBootConfig pairingJsonFromJson:
        @"{\"psk_hex\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
         "\"seed_peers\":[\"192.0.2.2:47172\"]}"
        secretRef:@"secret:mesh.psk"
        seeds:@[ @"192.0.2.1:47172", @"192.0.2.2:47172" ]];
    NSData *pairedData = [pairedJson dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *paired = [NSJSONSerialization JSONObjectWithData:pairedData
                                                            options:0 error:NULL];
    require([[paired objectForKey:@"psk_ref"] isEqualToString:@"secret:mesh.psk"],
            @"pairing persists the secure reference");
    require([paired objectForKey:@"psk_hex"] == nil,
            @"pairing removes plaintext PSK from boot JSON");
    require([[paired objectForKey:@"seed_peers"] isEqualToArray:@[
              @"192.0.2.1:47172", @"192.0.2.2:47172"
            ]], @"pairing merges and sorts seed addresses");

    NSDictionary *config = @{
      @"devices" : @{
        @"ipad-node" : @{
          @"role" : @"door_station",
          @"door" : @"front",
          @"local" : @{ @"camera" : @{ @"source_ref" : @"front_camera" } },
        },
      },
      @"media_sources" : @{
        @"front_camera" : @{
          @"schema_version" : @1,
          @"kind" : @"ip_camera",
          @"streams" : @{
            @"h264" : @{
              @"url" : @"rtsp://192.0.2.20/live",
              @"transport" : @"tcp",
              @"profile" : @"baseline",
            },
            @"mjpeg" : @{ @"url" : @"http://192.0.2.20/live.mjpeg" },
            @"snapshot" : @{ @"url" : @"https://192.0.2.20/snapshot.jpg" },
          },
          @"secret_ref" : @"secret:media.front_camera",
        },
      },
    };
    NSDictionary *peer = @{
      @"id" : @"ipad-node",
      @"role" : @"door_station",
      @"addrs" : @[ @"192.0.2.30:47172" ],
    };
    DBMediaSource *source = [DBMediaSource sourceForPeer:peer config:config
        boot:doorBoot() door:@"front" deviceID:nil];
    require([source.sourceRef isEqualToString:@"front_camera"], @"source_ref binding");
    require([source.deviceID isEqualToString:@"ipad-node"], @"peer device id");
    require([source.mjpegURL isEqualToString:@"http://192.0.2.20/live.mjpeg"],
            @"HTTP MJPEG URL");
    require([[source preferredPreviewTransport] isEqualToString:@"mjpeg"] &&
            [source supportsDirectJPEGPlayback],
            @"screen policy selects direct MJPEG before snapshot");
    require([source.snapshotURL isEqualToString:@"https://192.0.2.20/snapshot.jpg"],
            @"HTTPS snapshot URL");
    require(source.h264SourceAvailable && source.requiresH264Ingest,
            @"valid RTSP/TCP baseline source");
    require([source.h264URL isEqualToString:@"rtsp://192.0.2.20/live"] &&
            [source.h264Transport isEqualToString:@"tcp"] &&
            [source.h264Profile isEqualToString:@"baseline"],
            @"future Annex-B source component receives the exact H.264 contract");
    require([source.secretRef isEqualToString:@"secret:media.front_camera"],
            @"source retains only the credential reference");
    require([source.mp4URL length] == 0, @"RTSP must not be exposed as fMP4");
    require([source.degradedReason isEqualToString:@"rtsp_ingest_pending"],
            @"RTSP source remains pending until a measured IDR is forwarded");

    NSDictionary *userinfoConfig = @{
      @"devices" : @{ @"ipad-node" : @{
        @"role" : @"door_station", @"door" : @"front",
        @"local" : @{ @"camera" : @{ @"source_ref" : @"bad" } },
      } },
      @"media_sources" : @{ @"bad" : @{
        @"schema_version" : @1, @"kind" : @"ip_camera",
        @"streams" : @{ @"mjpeg" : @{ @"url" : @"http://user:pass@camera/live" } },
      } },
    };
    source = [DBMediaSource sourceForPeer:peer config:userinfoConfig
        boot:doorBoot() door:@"front" deviceID:nil];
    require(source.explicitlyUnavailable && [source.mjpegURL length] == 0,
            @"userinfo URL is rejected at the sink");

    NSDictionary *queryCredentialConfig = @{
      @"devices" : @{ @"ipad-node" : @{
        @"role" : @"door_station", @"door" : @"front",
        @"local" : @{ @"camera" : @{ @"source_ref" : @"bad_query" } },
      } },
      @"media_sources" : @{ @"bad_query" : @{
        @"schema_version" : @1, @"kind" : @"ip_camera",
        @"streams" : @{ @"snapshot" : @{
          @"url" : @"https://camera/snapshot.jpg?access_token=plaintext"
        } },
      } },
    };
    source = [DBMediaSource sourceForPeer:peer config:queryCredentialConfig
        boot:doorBoot() door:@"front" deviceID:nil];
    require(source.explicitlyUnavailable && [source.snapshotURL length] == 0,
            @"credential query URL is rejected at the sink");

    DBBootConfig *boot = doorBoot();
    boot.videoSource = @"ip_camera";
    boot.videoSnapshotURL = @"http://192.0.2.21/snapshot.jpg";
    source = [DBMediaSource sourceForPeer:nil config:@{} boot:boot
                                    door:@"front" deviceID:@"ipad-node"];
    require([source.sourceRef isEqualToString:@"legacy_boot"],
            @"legacy boot input is marked as migration data");
    require([source hasPreview] && ![source hasVideo], @"snapshot-only preview fallback");
    require([[source preferredPreviewTransport] isEqualToString:@"snapshot"],
            @"screen policy selects snapshot when MJPEG is absent");

    boot.videoMjpegURL = @"https://192.0.2.21/live.mjpeg";
    source = [DBMediaSource sourceForPeer:nil config:@{} boot:boot
                                    door:@"front" deviceID:@"ipad-node"];
    require([source.mjpegURL isEqualToString:@"https://192.0.2.21/live.mjpeg"] &&
            [[source preferredPreviewTransport] isEqualToString:@"mjpeg"],
            @"HTTPS MJPEG uses the bounded TLS-capable reader");

    DBBootConfig *indoor = [[DBBootConfig alloc] init];
    indoor.seedPeers = @[ @"192.0.2.99:47172" ];
    source = [DBMediaSource sourceForPeer:nil config:@{} boot:indoor
                                    door:@"front" deviceID:nil];
    require(![source hasPreview], @"seed address is not treated as a camera");

    NSDictionary *legacyPeer = @{
      @"id" : @"old-door", @"role" : @"door_station",
      @"addrs" : @[ @"192.0.2.40:47172" ],
    };
    source = [DBMediaSource sourceForPeer:legacyPeer config:@{} boot:indoor
                                    door:@"front" deviceID:nil];
    require([source.mjpegURL isEqualToString:@"http://192.0.2.40:47180/stream.mjpeg"],
            @"known legacy door peer fallback");
    puts("PASS: DBMediaSource schema and migration fallbacks");
  }
  return 0;
}
