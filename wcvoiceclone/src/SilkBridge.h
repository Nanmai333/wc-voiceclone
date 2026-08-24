#import <Foundation/Foundation.h>

/// 音频格式转换：任意音频(mp3/wav/m4a) → PCM → 微信语音用的 SILK v3
@interface WCSilkBridge : NSObject

/// 把 Fish Audio 返回的 mp3 数据转成微信可发送的 silk 格式 (24000Hz 单声道)
+ (NSData *)silkDataFromAudio:(NSData *)audioData error:(NSError **)error;

@end
