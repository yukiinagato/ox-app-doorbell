#import <Foundation/Foundation.h>

typedef void (^DBRTPH264AccessUnitHandler)(NSData *annexB, BOOL keyframe,
                                           uint32_t rtpTimestamp);

// Bounded RFC 6184 depacketizer for packetization-mode 1. It emits complete
// Annex-B access units and never decodes or re-encodes video on the A4 device.
@interface DBRTPH264Depacketizer : NSObject

@property(nonatomic, readonly) BOOL waitingForIDR;
@property(nonatomic, readonly) NSUInteger malformedPacketCount;

- (id)initWithAccessUnitHandler:(DBRTPH264AccessUnitHandler)handler;
- (void)seedSPS:(NSData *)sps pps:(NSData *)pps;
- (BOOL)consumeRTPPacket:(NSData *)packet expectedPayloadType:(uint8_t)payloadType;
- (void)markTransportLoss;
- (void)reset;

@end
