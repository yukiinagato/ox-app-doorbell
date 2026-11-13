#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

// iOS 5 RemoteIO bridge for 8 kHz mono SIP audio. The render callbacks exchange samples through
// bounded single-producer/single-consumer rings and never allocate or take Objective-C locks.
// Appends one line to Documents/audio-dbg.log (call diagnostics readable over SSH).
void DBAudioTrace(NSString *line);

@interface DBAudioIO : NSObject

@property(nonatomic, assign) BOOL micEnabled;

- (BOOL)start;
- (void)stop;
- (void)enqueueRx:(const short *)pcm count:(int)n;
- (int)dequeueTx:(short *)pcm max:(int)n;

@end
