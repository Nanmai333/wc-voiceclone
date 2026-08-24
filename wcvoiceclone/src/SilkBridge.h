#import <Foundation/Foundation.h>

/// PCM(s16le 单声道) → 微信语音用的 SILK v3
@interface WCSilkBridge : NSObject

/// 把 Fish Audio 返回的 PCM 数据 (format=pcm, sample_rate=24000) 编码成 silk
+ (NSData *)silkFromPCM:(NSData *)pcmData sampleRateHz:(int)hz error:(NSError **)error;

@end
