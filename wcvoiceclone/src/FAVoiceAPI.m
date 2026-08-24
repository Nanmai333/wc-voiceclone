#import "FAVoiceAPI.h"
#import "PrefsManager.h"

static NSString * const kBaseURL = @"https://api.fish.audio";

@implementation FAVoiceAPI

+ (instancetype)shared {
    static FAVoiceAPI *api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ api = [FAVoiceAPI new]; });
    return api;
}

- (void)request:(NSMutableURLRequest *)req
     completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    NSString *key = [WCPrefsManager shared].apiKey;
    if (key.length < 8) {
        completion(nil, nil, [NSError errorWithDomain:@"FA" code:-1
            userInfo:@{NSLocalizedDescriptionKey: @"未配置 API Key，请先在插件设置里填写"}]);
        return;
    }
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err) { completion(nil, nil, err); return; }
                NSInteger code = http.statusCode;
                if (code == 401) {
                    completion(nil, http, [NSError errorWithDomain:@"FA" code:401
                        userInfo:@{NSLocalizedDescriptionKey: @"API Key 无效 (401)，请到 fish.audio 后台重新生成"}]);
                    return;
                }
                if (code == 429) {
                    completion(nil, http, [NSError errorWithDomain:@"FA" code:429
                        userInfo:@{NSLocalizedDescriptionKey: @"请求太频繁或额度不足 (429)"}]);
                    return;
                }
                if (code >= 400) {
                    NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                    if (body.length > 300) body = [body substringToIndex:300];
                    completion(nil, http, [NSError errorWithDomain:@"FA" code:code
                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"接口错误 %ld: %@", (long)code, body]}]);
                    return;
                }
                completion(data, http, nil);
            });
        }];
    [task resume];
}

- (void)ttsText:(NSString *)text modelId:(NSString *)modelId completion:(FADataBlock)completion {
    NSURL *url = [NSURL URLWithString:[kBaseURL stringByAppendingString:@"/v1/tts"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    // 模型档位：s2.1-pro-free 免费开发档，不扣 API 积分
    NSString *model = [WCPrefsManager shared].ttsModel;
    if (model.length > 0) [req setValue:model forHTTPHeaderField:@"model"];
    NSDictionary *body = @{@"text": text ?: @"",
                           @"reference_id": modelId,
                           @"format": @"pcm",        // 直接要 PCM，免得插件里再解码 mp3
                           @"sample_rate": @24000,   // 微信 silk 标准采样率
                           @"temperature": @0.7,
                           @"top_p": @0.7,
                           @"normalize": @YES,
                           @"latency": @"normal"};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [self request:req completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        completion(data, err);
    }];
}

- (void)creditWithCompletion:(FAJSONBlock)completion {
    NSURL *url = [NSURL URLWithString:[kBaseURL stringByAppendingString:@"/wallet/self/api-credit"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [self request:req completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err) { completion(nil, err); return; }
        id json = nil;
        if (data) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        completion(json, json ? nil : [NSError errorWithDomain:@"FA" code:-2
            userInfo:@{NSLocalizedDescriptionKey: @"返回内容不是合法 JSON"}]);
    }];
}

- (void)cloneVoiceWithAudio:(NSData *)audioData title:(NSString *)title completion:(FAJSONBlock)completion {
    NSURL *url = [NSURL URLWithString:[kBaseURL stringByAppendingString:@"/model"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    NSString *boundary = @"WCVoiceCloneBoundary";
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
        forHTTPHeaderField:@"Content-Type"];

    NSMutableData *body = [NSMutableData data];
    void (^addField)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
                           boundary, name, value] dataUsingEncoding:NSUTF8StringEncoding]];
    };
    addField(@"type", @"tts");
    addField(@"title", title ?: @"我的克隆声音");
    addField(@"train_mode", @"fast");
    addField(@"visibility", @"private");
    [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"voices\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:audioData];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    req.HTTPBody = body;
    [self request:req completion:^(NSData *data, NSHTTPURLResponse *http, NSError *err) {
        if (err) { completion(nil, err); return; }
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        completion(json, json ? nil : [NSError errorWithDomain:@"FA" code:-2
            userInfo:@{NSLocalizedDescriptionKey: @"克隆接口返回异常"}]);
    }];
}

@end
