#import <Foundation/Foundation.h>

typedef void (^FADataBlock)(NSData *data, NSError *error);
typedef void (^FAJSONBlock)(NSDictionary *json, NSError *error);

// Fish Audio API 客户端 (https://docs.fish.audio)
@interface FAVoiceAPI : NSObject

+ (instancetype)shared;

/// 文字转语音（用克隆的声音模型）
/// @param text 要念的文本
/// @param modelId 声音模型 ID
/// @param completion 成功返回 mp3 音频数据
- (void)ttsText:(NSString *)text
         modelId:(NSString *)modelId
      completion:(FADataBlock)completion;

/// 查询 API 点数余额
- (void)creditWithCompletion:(FAJSONBlock)completion;

/// 上传音频克隆声音 (fast 模式)
/// @param audioData 人声录音数据 (wav/mp3)
/// @param title 声音名称
/// @param completion 返回创建结果(含模型 ID)
- (void)cloneVoiceWithAudio:(NSData *)audioData
                      title:(NSString *)title
                 completion:(FAJSONBlock)completion;

@end
