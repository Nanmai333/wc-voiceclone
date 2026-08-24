#import "SilkBridge.h"
#ifdef HAVE_SILK
#include "SKP_Silk_SDK_API.h"
#include <string.h>
#endif

static NSString * const kErrDomain = @"WCSilkBridge";

@implementation WCSilkBridge

+ (NSData *)silkFromPCM:(NSData *)pcmData sampleRateHz:(int)hz error:(NSError **)error {
#ifdef HAVE_SILK
    const SKP_int32 rate = hz;
    const SKP_int frameSamples = rate / 50;   // 20ms 帧 @24kHz = 480 samples

    // 1. 创建编码器
    SKP_int32 encSizeBytes = 0;
    SKP_Silk_SDK_Get_Encoder_Size(&encSizeBytes);
    void *encState = malloc(encSizeBytes);
    if (!encState) {
        if (error) *error = [NSError errorWithDomain:kErrDomain code:-1
            userInfo:@{NSLocalizedDescriptionKey: @"内存分配失败"}];
        return nil;
    }

    // 2. 初始化 + 配置（微信语音典型参数）
    SKP_SILK_SDK_EncControlStruct ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    SKP_Silk_SDK_InitEncoder(encState, &ctrl);

    ctrl.API_sampleRate        = rate;
    ctrl.maxInternalSampleRate = 24000;
    ctrl.packetSize            = frameSamples;      // 20ms
    ctrl.bitRate               = 25000;
    ctrl.packetLossPercentage  = 0;
    ctrl.complexity            = 2;
    ctrl.useInBandFEC          = 0;
    ctrl.useDTX                = 0;

    // 3. 输出文件头
    NSMutableData *silk = [NSMutableData dataWithData:
                           [@"#!SILK_V3" dataUsingEncoding:NSUTF8StringEncoding]];

    // 4. 逐帧编码（最后一帧补零）
    const SKP_int16 *samples = (const SKP_int16 *)pcmData.bytes;
    SKP_int totalSamples = (SKP_int)(pcmData.length / sizeof(SKP_int16));
    uint8_t outBuf[1024];
    SKP_int16 frameBuf[960];

    for (SKP_int pos = 0; pos < totalSamples; pos += frameSamples) {
        memset(frameBuf, 0, sizeof(frameBuf));
        memcpy(frameBuf, samples + pos,
               MIN(frameSamples, totalSamples - pos) * sizeof(SKP_int16));

        SKP_int16 nOut = sizeof(outBuf);
        SKP_int ret = SKP_Silk_SDK_Encode(encState, &ctrl, frameBuf, frameSamples,
                                          outBuf, &nOut);
        if (ret != 0) break;
        if (nOut > 0) [silk appendBytes:outBuf length:nOut];
    }
    free(encState);

    if (silk.length <= 9) {
        if (error) *error = [NSError errorWithDomain:kErrDomain code:-20
            userInfo:@{NSLocalizedDescriptionKey: @"SILK 编码结果为空"}];
        return nil;
    }
    NSLog(@"[WCVoiceClone] pcm %lu bytes → silk %lu bytes",
          (unsigned long)pcmData.length, (unsigned long)silk.length);
    return silk;
#else
    if (error) *error = [NSError errorWithDomain:kErrDomain code:-30
        userInfo:@{NSLocalizedDescriptionKey: @"未编译 SILK 支持"}];
    return nil;
#endif
}

@end
