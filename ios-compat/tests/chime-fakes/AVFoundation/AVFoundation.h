#import <Foundation/Foundation.h>

@interface AVAudioPlayer : NSObject
@property(nonatomic) NSInteger numberOfLoops;
@property(nonatomic) float volume;
- (id)initWithData:(NSData *)data error:(NSError **)error;
- (id)initWithContentsOfURL:(NSURL *)url error:(NSError **)error;
- (BOOL)prepareToPlay;
- (BOOL)play;
- (void)stop;
@end
