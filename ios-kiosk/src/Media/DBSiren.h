#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

// カスタム音声/内蔵サイレンの再生。1 プレイヤを差し替えながら使う。
@interface DBSiren : NSObject

// asset 音声を 1 回再生。失敗時は NO (呼び出し側がシステム音へ回落)。
- (BOOL)playAssetPath:(NSString *)path;

// カスタム資産があれば優先し、無ければ ding1 / ding2 / classic の内蔵鈴音を再生。
- (void)playChimeSound:(NSString *)sound assetPath:(NSString *)path;

// 警報音をループ再生。customPath が有効ならそれ、無ければ内蔵生成音。
- (void)startSiren:(NSString *)customPath volume:(NSInteger)volume;

- (void)stop;

@end
