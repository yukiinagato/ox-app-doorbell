#import "DBConversationTransport.h"
#import "DBSipSession.h"
#import "../Core/DBCoreBridge.h"

@interface DBConversationTransport () <DBMiniSipDelegate>
@end
@implementation DBConversationTransport {
  __weak DBCoreBridge *_core;
  NSMutableDictionary *_sessions;
}
- (id)initWithCore:(DBCoreBridge *)core {
  self = [super init];
  if (self) { _core = core; _sessions = [[NSMutableDictionary alloc] init]; }
  return self;
}
- (void)handleEvent:(NSDictionary *)event {
  if (![[event objectForKey:@"t"] isEqual:@"conversation_transport"]) return;
  NSMutableSet *desired = [NSMutableSet set];
  NSArray *items = [event objectForKey:@"sessions"];
  // Release the old audio unit before opening another door's microphone.
  for (DBSipSession *session in [_sessions allValues]) [session setAudioHeld:YES];
  for (NSDictionary *item in items) {
    NSString *mode = [item objectForKey:@"mode"];
    NSString *target = [item objectForKey:@"target"];
    if (![mode isKindOfClass:[NSString class]] || ![target hasPrefix:@"sip:"]) continue;
    [desired addObject:mode];
    DBSipSession *session = [_sessions objectForKey:mode];
    if (!session) {
      NSURL *url = [NSURL URLWithString:[@"http://" stringByAppendingString:[target substringFromIndex:4]]];
      NSString *auth = [_core conversationAuth:mode];
      if ([auth length] == 0 || [[url host] length] == 0) continue;
      session = [[DBSipSession alloc] initWithHost:[url host] port:[[url port] intValue]
                                            mode:mode micEnabled:YES];
      session.peerAuthentication = auth;
      session.delegate = self;
      [session setAudioHeld:YES];
      [_sessions setObject:session forKey:mode];
      [session start];
    }
    [session setAudioHeld:[[item objectForKey:@"held"] boolValue]];
  }
  for (NSString *mode in [_sessions allKeys]) if (![desired containsObject:mode]) {
    DBSipSession *session = [_sessions objectForKey:mode];
    session.delegate = nil;
    [session hangup];
    [_sessions removeObjectForKey:mode];
  }
}
- (void)miniSipStateChanged:(DBMiniSipState)state { (void)state; }
- (void)miniSipSession:(DBSipSession *)session stateChanged:(DBMiniSipState)state {
  for (NSString *mode in [_sessions allKeys]) if ([_sessions objectForKey:mode] == session) {
    if (state == DBMiniSipInCall || state == DBMiniSipEnded)
      [_core conversationMedia:mode connected:state == DBMiniSipInCall];
    if (state == DBMiniSipEnded) [_sessions removeObjectForKey:mode];
    return;
  }
}
- (void)stop {
  for (DBSipSession *session in [_sessions allValues]) { session.delegate = nil; [session hangup]; }
  [_sessions removeAllObjects];
}
@end
