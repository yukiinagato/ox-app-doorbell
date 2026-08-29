// SOS サイレン + カスタム音声再生 (ios/Doorbell/SirenPlayer.swift の MRC 移植・簡略)。
// サイレン波形 (880/660Hz 交互 2 秒 PCM WAV) を実行時生成しループ。emergency の audio_path
// (カスタム警報音) 優先、失敗時に内蔵サイレンへ回落。reply/chime の audio_path は 1 回再生。
#import <Foundation/Foundation.h>

@interface DBSirenPlayer : NSObject

// 資産ローカルファイルを 1 回再生。失敗時は失敗を返す (呼び出し側が回落)。
- (BOOL)playAssetPath:(NSString *)path;
// ui.*_sound の値 (内蔵 preset / asset:<sha256> / 空文字) を再生。
- (BOOL)playConfigured:(NSString *)value dataDir:(NSString *)dataDir loop:(BOOL)loop;
// 警報開始。customPath 優先、無ければ内蔵サイレン。volume 0-100。
- (void)startSiren:(NSString *)customPath volume:(NSInteger)volume;
- (void)stop;

@end
