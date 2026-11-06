#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>


@interface DBSiren : NSObject


- (BOOL)playAssetPath:(NSString *)path;


- (BOOL)playConfiguredSound:(NSString *)value loop:(BOOL)loop;


// Main-thread entry; a serial audio queue owns chime preparation/playback and cancellation.
- (void)playChimeSound:(NSString *)sound assetPath:(NSString *)path;


- (void)startSiren:(NSString *)customPath volume:(NSInteger)volume;

- (void)stop;

@end
