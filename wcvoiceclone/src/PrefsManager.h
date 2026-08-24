#import <Foundation/Foundation.h>

// 读取/保存插件配置（CFPreferences，重启微信后仍在）
@interface WCPrefsManager : NSObject

+ (instancetype)shared;

/// Fish Audio API Key
@property (nonatomic, copy) NSString *apiKey;
/// 克隆声音模型 ID (reference_id)
@property (nonatomic, copy) NSString *modelId;
/// 聊天页悬浮球开关
@property (nonatomic, assign) BOOL floatBallEnabled;

- (void)save;
- (BOOL)isConfigured;

@end
