#import "SilkBridge.h"
#import <AVFoundation/AVFoundation.h>
#ifdef HAVE_SILK
#include "SKP_Silk_SDK_API.h"
#endif

static NSString * const kErrDomain = @"WCSilkBridge";

@implementation WCSilkBridge

#pragma mark - PCM 解码 (mp3/wav/m4a → Int16 @24kHz mono)

+ (NSData *)pcmDataFromAudio:(NSData *)audioData
                    sampleRate:(double)sampleRate
                         error:(NSError **)error {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wcv_tts_in.mp3"];
    [audioData writeToFile:tmp atomically:YES];

    AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:tmp] error:error];
    if (!file) return nil;

    AVAudioFormat *srcFmt = file.processingFormat;
    AVAudioFrameCount cap = (AVAudioFrameCount)file.length + srcFmt.sampleRate * 0.5; // 余量
    if (cap < 1024) cap = 1024;
    AVAudioPCMBuffer *srcBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:srcFmt frameCapacity:cap error:nil];
    if (![file readIntoBuffer:srcBuf error:error]) return nil;
    if (srcBuf.frameLength == 0) {
        *error = [NSError errorWithDomain:kErrDomain code:-10
            userInfo:@{NSLocalizedDescriptionKey: @"解码后音频为空"}];
        return nil;
    }

    AVAudioFormat *dstFmt = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatInt16
        sampleRate:sampleRate channels:1 interleaved:YES];
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:srcFmt toFormat:dstFmt];
    if (!conv) {
        *error = [NSError errorWithDomain:kErrDomain code:-11
            userInfo:@{NSLocalizedDescriptionKey: @"无法创建音频转换器"}];
        return nil;
    }

    double ratio = sampleRate / srcFmt.sampleRate;
    AVAudioFrameCount dstCap = (AVAudioFrameCount)(srcBuf.frameLength * ratio) + 4096;
    AVAudioPCMBuffer *dstBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:dstCap error:nil];

    __block BOOL consumed = NO;
    NSError *convErr = nil;
    [conv convertToBuffer:dstBuf error:&convErr withInputBlock:^AVAudioBuffer *(AVAudioPacketCount inNumPackets, AVAudioPacketStatus *outStatus) {
        if (consumed) { *outStatus = AVAudioConverterInputStatus_EndOfStream; return nil; }
        consumed = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return srcBuf;
    }];
    if (convErr) { *error = convErr; return nil; }
    if (dstBuf.frameLength == 0) {
        *error = [NSError errorWithDomain:kErrDomain code:-12
            userInfo:@{NSLocalizedDescriptionKey: @"重采样后音频为空"}];
        return nil;
    }

    NSData *pcm = [NSData dataWithBytes:dstBuf.int16ChannelData[0]
                                 length:dstBuf.frameLength * 2 /* int16 = 2 bytes */];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return pcm;
}

#pragma mark - SILK 编码

#ifdef HAVE_SILK
+ (NSData *)encodeSilkFromPCM:(NSData *)pcmData
                   sampleRate:(SKP_int32)sampleRate {
    SKP_int32 encSizeBytes = 0;
    SKP_Silk_SDK_Get_Encoder_Size(&encSizeBytes);
    void *encState = malloc(encSizeBytes);
    SKP_Silk_SDK_Encode_Init(encState);

    SKP_SILK_SDK_EncControlStruct ctrl = {0};
    ctrl.API_sampleRate = sampleRate;      // 输入采样率
    ctrl.packetSize     = sampleRate / 50; // 20ms 帧
    ctrl.packetLossPercentage = 0;
    ctrl.useDTX         = 0;
    ctrl.complexity     = 2;               // 手机上低复杂度即可
    ctrl.bitRate        = 25000;           // 微信语音典型码率
    ctrl.inBandFECUsage = 0;

    NSMutableData *silk = [NSMutableData dataWithData:[@"#!SILK_V3" dataUsingEncoding:NSUTF8StringEncoding]];

    const SKP_int16 *samples = (const SKP_int16 *)pcmData.bytes;
    SKP_int totalSamples = (SKP_int)(pcmData.length / 2);
    uint8_t outBuf[4096];
    const SKP_int frameSize = sampleRate / 50; // 20ms @24kHz = 480 samples
    SKP_int16 frameBuf[960];

    for (SKP_int pos = 0; pos < totalSamples; pos += frameSize) {
        // silk 要求固定帧大小，最后一帧不足补零
        memset(frameBuf, 0, sizeof(frameBuf));
        memcpy(frameBuf, samples + pos, MIN(frameSize, totalSamples - pos) * sizeof(SKP_int16));

        ctrl.API_sampleRate = sampleRate;
        SKP_int16 nOut = sizeof(outBuf);
        SKP_int ret = SKP_Silk_SDK_Encode(encState, &ctrl, frameBuf, frameSize,
                                          (SKP_uint8 *)outBuf, &nOut);
        if (ret == 0 && nOut > 0) {
            [silk appendBytes:outBuf length:nOut];
        } else {
            break;
        }
    }
    free(encState);
    return silk;
}
#endif

+ (NSData *)silkDataFromAudio:(NSData *)audioData error:(NSError **)error {
#ifdef HAVE_SILK
    const double rate = 24000.0;
    NSData *pcm = [self pcmDataFromAudio:audioData sampleRate:rate error:error];
    if (!pcm) return nil;

    // 去掉 wav 头部残留的直流偏置问题不大，直接编码
    NSData *silk = [self encodeSilkFromPCM:pcm sampleRate:(SKP_int32)rate];
    if (silk.length <= 9) {
        *error = [NSError errorWithDomain:kErrDomain code:-20
            userInfo:@{NSLocalizedDescriptionKey: @"SILK 编码结果为空"}];
        return nil;
    }
    NSLog(@"[WCVoiceClone] mp3 %lu bytes → pcm %lu bytes → silk %lu bytes",
          (unsigned long)audioData.length, (unsigned long)pcm.length, (unsigned long)silk.length);
    return silk;
#else
    *error = [NSError errorWithDomain:kErrDomain code:-30
        userInfo:@{NSLocalizedDescriptionKey: "未编译 SILK 支持"}];
    return nil;
#endif
}

@end
