

// Objective-C owner for one MiniSIP UAC session. Polling and audio run off the main thread; state
// notifications are marshaled to the main thread and the delegate is weak.





#import <Foundation/Foundation.h>
#import "DBCallSession.h"


typedef enum {
  DBMiniSipCalling = 0,
  DBMiniSipInCall = 1,
  DBMiniSipEnded = 2,
  DBMiniSipRinging = 3,
  DBMiniSipListening = 4
} DBMiniSipState;

@protocol DBMiniSipDelegate <NSObject>
- (void)miniSipStateChanged:(DBMiniSipState)state;
@end

@interface DBSipSession : NSObject <DBCallSession>

@property(nonatomic, weak) id<DBMiniSipDelegate> delegate;



- (id)initWithHost:(NSString *)host port:(int)port mode:(NSString *)mode micEnabled:(BOOL)micEnabled;
- (void)start;
- (void)hangup;
- (void)sendDtmf:(NSString *)digits;

@end
