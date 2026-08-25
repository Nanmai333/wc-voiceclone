// WCVoiceClone - 用 Fish Audio 克隆声音在微信发语音
// Theos/Logos 越狱插件 (个人自用)
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>
#import "src/PrefsManager.h"
#import "src/FAVoiceAPI.h"
#import "src/SilkBridge.h"

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// 微信聊天页基类（Logos 只会前置声明，这里补全继承关系）
@interface BaseMsgContentViewController : UIViewController
// 以下是 %new 运行时添加的方法，需提前声明才能编译
- (void)wcv_ballTapped;
- (void)wcv_promptTTS;
- (void)wcv_synthAndSend:(NSString *)text;
- (void)wcv_replaceHud:(UIViewController *)hud message:(NSString *)message;
- (void)wcv_testAPI;
- (void)wcv_openSettings;
- (void)wcv_debugProbe;
@end

static void WCVAddBallIfNeeded(UIViewController *vc);
static void WCVShowBanner(UIWindow *window);
static NSString *WCVOwnWxId(void);
static BOOL WCVLooksLikeWxId(id v);

#pragma mark - 工具函数

// 防御性写入对象属性：字段名列表逐个尝试，不存在就跳过
static void WCVSafeSet(id obj, NSArray *keys, id value) {
    for (NSString *key in keys) {
        @try {
            [obj setValue:value forKey:key];
            return;
        } @catch (NSException *e) { /* 没有这个属性，试下一个 */ }
    }
}

// 获取微信"服务中心"单例：8.0.76 已移除 +[MMServiceCenter defaultCenter]，运行时自动探测新入口
static id WCVServiceCenter(void) {
    // 方案1: 旧版类方法（兼容老微信）
    Class sc = NSClassFromString(@"MMServiceCenter");
    if (sc && [sc respondsToSelector:NSSelectorFromString(@"defaultCenter")]) {
        id c = nil;
        @try { c = [sc performSelector:NSSelectorFromString(@"defaultCenter")]; } @catch (NSException *e) {}
        if (c) return c;
    }
    // 方案2: 扫描所有 *ServiceCenter* / MMContext 类，找能响应 getService: 的单例
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    id result = nil;
    for (unsigned int i = 0; i < n && !result; i++) {
        const char *nm = class_getName(list[i]);
        BOOL candidate = (strstr(nm, "ServiceCenter") != NULL) || (strcmp(nm, "MMContext") == 0);
        if (!candidate) continue;
        if (!class_getInstanceMethod(list[i], NSSelectorFromString(@"getService:"))) continue;
        NSArray<NSString *> *singletonNames = @[@"defaultCenter", @"sharedCenter", @"sharedInstance",
                                                @"shared", @"currentContext", @"activeContext", @"current"];
        for (NSString *selName in singletonNames) {
            SEL s = NSSelectorFromString(selName);
            if (![list[i] respondsToSelector:s]) continue;
            @try {
                id c = [list[i] performSelector:s];
                if (c) {
                    NSLog(@"[WCVoiceClone] 服务中心: %s 单例方法: %@", nm, selName);
                    result = c;
                }
            } @catch (NSException *e) {}
            if (result) break;
        }
    }
    free(list);
    return result;
}

// 安全取服务实例
static id WCVGetService(Class svcClass) {
    if (!svcClass) return nil;
    id c = WCVServiceCenter();
    if (!c) return nil;
    SEL g = NSSelectorFromString(@"getService:");
    if (![c respondsToSelector:g]) return nil;
    id svc = nil;
    @try { svc = [c performSelector:g withObject:svcClass]; } @catch (NSException *e) {}
    return svc;
}

// 判断字符串是否像微信用户 ID（wxid_xx / 自定义号 / xxx@chatroom）
static BOOL WCVLooksLikeWxId(id v) {
    if (![v isKindOfClass:NSString.class]) return NO;
    NSString *s = (NSString *)v;
    if (s.length < 4 || s.length > 64) return NO;
    static NSPredicate *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = [NSPredicate predicateWithFormat:@"SELF MATCHES %@",
             @"^[A-Za-z][A-Za-z0-9_-]{3,62}(@chatroom|@openim)?$"];
    });
    return [p evaluateWithObject:s];
}

// 当前聊天对象的 wxid：先猜常见字段名，再全量扫描 ivar 自动发现
static NSString *WCVCurrentChatUser(UIViewController *vc) {
    NSString *own = WCVOwnWxId();

    // 1. 常见字段名（历史版本）
    NSArray<NSString *> *keys = @[@"m_nsChatUsr", @"m_nsToUsr", @"chatUsr",
                                  @"m_chatUsr", @"nsChatUsr", @"chatUserName",
                                  @"m_nsChatUserName", @"m_szChatUsr"];
    for (NSString *key in keys) {
        id v = nil;
        @try { v = [vc valueForKey:key]; } @catch (NSException *e) {}
        if (WCVLooksLikeWxId(v) && ![v isEqualToString:own]) return v;
    }

    // 2. 扫描类及父类所有 ivar；优先名字带 chat/to/talker 的
    Class c = [vc class];
    while (c) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(c, &n);
        NSString *fallback = nil;
        for (unsigned int i = 0; i < n; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;   // 只要对象类型字段
            id v = nil;
            @try { v = object_getIvar(vc, ivars[i]); } @catch (NSException *e) { continue; }
            if (!WCVLooksLikeWxId(v) || [v isEqualToString:own]) continue;
            const char *iname = ivar_getName(ivars[i]);
            NSString *lower = [NSString stringWithUTF8String:iname].lowercaseString;
            NSLog(@"[WCVoiceClone] candidate ivar %s = %@", iname, v);
            if ([lower containsString:@"chat"] || [lower containsString:@"touser"] ||
                [lower containsString:@"talker"]) {
                free(ivars);
                return v;
            }
            if (!fallback) fallback = v;
        }
        free(ivars);
        if (fallback) return fallback;
        c = class_getSuperclass(c);
    }
    return nil;
}

// 自己的 wxid
static NSString *WCVOwnWxId(void) {
    for (NSString *svcName in @[@"CAccountMgr", @"CContactMgr"]) {
        Class svcClass = NSClassFromString(svcName);
        if (!svcClass) continue;
        id mgr = WCVGetService(svcClass);
        if (!mgr) continue;
        // 直接在 mgr 上找，或在 selfContact 上找
        NSArray<NSArray<NSString *> *> *paths = @[
            @[@"m_nsUsrName"], @[@"m_nsUserName"],
            @[@"selfContact", @"m_nsUsrName"],
            @[@"m_oMyContact", @"m_nsUsrName"],
        ];
        for (NSArray<NSString *> *path in paths) {
            id v = mgr;
            BOOL ok = YES;
            for (NSString *key in path) {
                id next = nil;
                @try { next = [v valueForKey:key]; } @catch (NSException *e) { ok = NO; break; }
                v = next;
            }
            if (ok && [v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) return v;
        }
    }
    return nil;
}

// 用剪贴板友好的可变日志收集发送过程
typedef void (^WCVDoneBlock)(BOOL ok, NSString *log);

// 发送语音消息：优先已知方法名，失败则运行时扫描所有消息服务类自动适配
static BOOL WCVTrySendVoice(NSData *silk, NSString *toUser, unsigned int durationSec, NSMutableString *log) {
    Class msgWrapClass = NSClassFromString(@"CMessageWrap");
    if (!msgWrapClass) {
        [log appendString:@"缺少核心类 CMessageWrap\n"];
        return NO;
    }
    @try {
    NSString *fromUser = WCVOwnWxId() ?: @"";

    // ① 构造语音消息：优先用官方初始化器（完成内部状态装配）
    id msg = nil;
    SEL initSel = NSSelectorFromString(@"initWithMsgType:nsFromUsr:");
    if ([msgWrapClass instancesRespondToSelector:initSel]) {
        NSMethodSignature *sig = [msgWrapClass instanceMethodSignatureForSelector:initSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        id alloced = [msgWrapClass alloc];
        long long msgType = 34;   // 34=语音
        [inv setTarget:alloced];
        [inv setSelector:initSel];
        [inv setArgument:&msgType atIndex:2];
        [inv setArgument:&fromUser atIndex:3];
        [inv invoke];
        void *retObj = NULL;
        [inv getReturnValue:&retObj];
        msg = (__bridge id)retObj;
        [log appendString:@"✓ 使用 initWithMsgType:nsFromUsr: 初始化\n"];
    }
    if (!msg) msg = [[msgWrapClass alloc] init];

    // ② 语音消息关键字段（对照两份开源实现逐项设置）
    WCVSafeSet(msg, @[@"m_uiMessageType", @"m_iMessageType"], @34);
    WCVSafeSet(msg, @[@"m_nsFromUsr"], fromUser);
    WCVSafeSet(msg, @[@"m_nsToUsr", @"m_nsTalker", @"m_nsChatUsr"], toUser);
    WCVSafeSet(msg, @[@"m_nsContent"], @"[语音]");
    WCVSafeSet(msg, @[@"m_uiVoiceFormat", @"m_voiceFormat", @"m_cVoiceFormat"], @4); // 4=SILK
    WCVSafeSet(msg, @[@"m_uiVoiceEndFlag"], @1);                                     // 结束标志
    WCVSafeSet(msg, @[@"m_uiVoiceTime", @"m_nVoiceTime"],
               @(durationSec * 1000));                                               // 毫秒！
    WCVSafeSet(msg, @[@"m_nTotalLen"], @(durationSec));                              // 秒（旧字段）
    WCVSafeSet(msg, @[@"m_dtVoice", @"nativeVoiceData"], silk);
    WCVSafeSet(msg, @[@"m_uiCreateTime"], @((unsigned int)[NSDate date].timeIntervalSince1970));

    // ③ 把 silk 数据写到微信期望的磁盘路径（上传管理器从文件读取）
    SEL gp = NSSelectorFromString(@"getPathOfMsgImg:");
    if ([msgWrapClass respondsToSelector:gp]) {
        @try {
            NSString *p = [msgWrapClass performSelector:gp withObject:msg];
            if ([p isKindOfClass:NSString.class]) {
                p = [(NSString *)p stringByReplacingOccurrencesOfString:@"Img" withString:@"Audio"];
                p = [(NSString *)p stringByReplacingOccurrencesOfString:@".pic" withString:@".aud"];
                NSString *dir = [p stringByDeletingLastPathComponent];
                [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES attributes:nil error:nil];
                [silk writeToFile:p atomically:YES];
                [log appendFormat:@"✓ 音频已写入磁盘 (%.1f KB)\n", silk.length / 1024.0];
            }
        } @catch (NSException *e) {
            [log appendFormat:@"- 写音频文件跳过: %@\n", e.reason];
        }
    }

    // ④ 发送通道：优先 AudioSender ResendVoiceMsg（两份开源实现验证的完整管线），
    //    备选 CMessageMgr AddMsg / AddLocalMsg
    NSArray<NSArray *> *channels = @[
        @[@"AudioSender", @"ResendVoiceMsg:MsgWrap:"],
        @[@"CMessageMgr", @"AddMsg:MsgWrap:"],
        @[@"CMessageMgr", @"AddLocalMsg:MsgWrap:"],
    ];
    for (NSArray *ch in channels) {
        NSString *svcName = ch[0], *selName = ch[1];
        Class cls = NSClassFromString(svcName);
        if (!cls) continue;
        id svc = WCVGetService(cls);
        if (!svc) { [log appendFormat:@"- %@ 服务不可用\n", svcName]; continue; }
        SEL sel = NSSelectorFromString(selName);
        NSMethodSignature *sig = [svc methodSignatureForSelector:sel];
        if (![svc respondsToSelector:sel] || !sig) continue;
        NSInteger nArgs = sig.numberOfArguments - 2;
        if (nArgs != 2) continue;
        const char *t2 = [sig getArgumentTypeAtIndex:2];
        const char *t3 = [sig getArgumentTypeAtIndex:3];
        if (!t2 || t2[0] != '@' || !t3 || t3[0] != '@') continue;

        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:svc];
            [inv setSelector:sel];
            [inv setArgument:&toUser atIndex:2];
            [inv setArgument:&msg atIndex:3];
            [inv invoke];
            [log appendFormat:@"✅ [%@ %@] 调用成功\n", svcName, selName];
            return YES;
        } @catch (NSException *e) {
            [log appendFormat:@"⚠️ [%@ %@] 异常: %@\n", svcName, selName, e.reason];
        }
    }
    [log appendString:@"❌ 所有发送通道都失败了。\n"];
    return NO;
    } @catch (NSException *e) {
        [log appendFormat:@"⚠️ 发送过程异常: %@\n", e.reason];
        return NO;
    }
}

#pragma mark - 自检横幅 + 运行时适配不同微信版本的聊天类

static void WCVShowBanner(UIWindow *window) {
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(20, 90, window.bounds.size.width - 40, 44)];
    banner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    banner.layer.cornerRadius = 12;
    banner.userInteractionEnabled = NO;
    UILabel *label = [[UILabel alloc] initWithFrame:banner.bounds];
    label.text = @"🎤 WCVoiceClone 已注入";
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:15];
    [banner addSubview:label];
    [window addSubview:banner];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [banner removeFromSuperview]; });
}

// 运行时扫描所有名字带 MsgContentViewController 的类，挂钩 viewDidAppear:
// 这样不管哪个微信版本、类名怎么变，都能挂上悬浮球
static NSMutableDictionary<NSString *, NSValue *> *WCVOrigIMPs = nil;

static void wcv_swz_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    Class c = [self class];
    IMP orig = NULL;
    while (c) { // 找最近的被挂钩祖先类，调用原实现
        NSValue *v = WCVOrigIMPs[NSStringFromClass(c)];
        if (v) { orig = (IMP)[v pointerValue]; break; }
        c = class_getSuperclass(c);
    }
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated);
    @try { WCVAddBallIfNeeded((UIViewController *)self); } @catch (NSException *e) {}
}

static void WCVRuntimeHookChatVCs(void) {
    WCVOrigIMPs = [NSMutableDictionary new];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    SEL sel = NSSelectorFromString(@"viewDidAppear:");
    int hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *n = class_getName(classes[i]);
        if (!strstr(n, "MsgContentViewController")) continue;
        Method m = class_getInstanceMethod(classes[i], sel);
        if (!m) continue;
        IMP cur = method_getImplementation(m);
        if (cur == (IMP)wcv_swz_viewDidAppear) continue;
        NSString *clsName = NSStringFromClass(classes[i]);
        if (WCVOrigIMPs[clsName]) continue;
        WCVOrigIMPs[clsName] = [NSValue valueWithPointer:cur];
        method_setImplementation(m, (IMP)wcv_swz_viewDidAppear);
        hooked++;
        NSLog(@"[WCVoiceClone] hooked chat VC: %s", n);
    }
    free(classes);
    NSLog(@"[WCVoiceClone] runtime-hooked %d chat VC classes", hooked);
}

#pragma mark - 悬浮球添加逻辑（供多个入口复用）

static void WCVAddBallIfNeeded(UIViewController *vc) {
    if (![WCPrefsManager shared].floatBallEnabled) return;
    UIView *rootView = vc.view;
    if (!rootView) return;

    // 避免重复添加
    for (UIView *sub in rootView.subviews) {
        if (sub.tag == 0x1990) return;
    }

    UIButton *ball = [UIButton buttonWithType:UIButtonTypeSystem];
    ball.tag = 0x1990;
    ball.layer.cornerRadius = 22;
    ball.clipsToBounds = YES;
    ball.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    ball.titleLabel.font = [UIFont systemFontOfSize:20];
    [ball setTitle:@"🎤" forState:UIControlStateNormal];
    ball.frame = CGRectMake(rootView.bounds.size.width - 64,
                            rootView.bounds.size.height - 180, 44, 44);
    ball.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [ball addTarget:vc action:@selector(wcv_ballTapped) forControlEvents:UIControlEventTouchUpInside];
    [rootView addSubview:ball];
}

#pragma mark - Hook 主入口

%hook BaseMsgContentViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    WCVAddBallIfNeeded(self);
}

%new
- (void)wcv_ballTapped {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"WCVoiceClone"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    [menu addAction:[UIAlertAction actionWithTitle:@"🎤 输入文字用克隆声音发送"
                                             style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                                                 [self wcv_promptTTS];
                                             }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"🧪 测试 Fish Audio 连接"
                                             style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                                                 [self wcv_testAPI];
                                             }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"⚙️ 设置 API Key / 声音模型"
                                             style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                                                 [self wcv_openSettings];
                                             }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"🐞 调试: 探测本版微信接口"
                                             style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                                                 [self wcv_debugProbe];
                                             }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}

// 展示结果（先关掉等待框再弹结果）
%new
- (void)wcv_replaceHud:(UIViewController *)hud message:(NSString *)message {
    [hud dismissViewControllerAnimated:YES completion:^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                    message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

%new
- (void)wcv_promptTTS {
    if (![WCPrefsManager shared].isConfigured) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"还没配置"
                            message:@"先去「设置」里填 Fish Audio 的 API Key 和克隆好的声音模型 ID"
                            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"去设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self wcv_openSettings];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"克隆语音"
                            message:@"输入要念的文字，将用你的克隆声音发到当前聊天"
                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"例如：收到，马上处理～";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        if (text.length == 0) return;
        [self wcv_synthAndSend:text];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)wcv_synthAndSend:(NSString *)text {
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:nil
                            message:@"1/3 合成语音中…" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *wait = [UIAlertAction actionWithTitle:@"请稍候…" style:UIAlertActionStyleDefault handler:nil];
    wait.enabled = NO;
    [hud addAction:wait];
    [self presentViewController:hud animated:YES completion:nil];

    WCPrefsManager *prefs = [WCPrefsManager shared];
    [[FAVoiceAPI shared] ttsText:text modelId:prefs.modelId completion:^(NSData *data, NSError *error) {
        if (error) {
            [self wcv_replaceHud:hud message:[NSString stringWithFormat:@"❌ 合成失败：%@", error.localizedDescription]];
            return;
        }
        hud.message = @"2/3 SILK 编码中…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *silkErr = nil;
            NSData *silk = [WCSilkBridge silkFromPCM:data sampleRateHz:24000 error:&silkErr];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!silk) {
                    [self wcv_replaceHud:hud message:[NSString stringWithFormat:@"❌ SILK 编码失败：%@", silkErr.localizedDescription]];
                    return;
                }
                hud.message = @"3/3 发送中…";
                // 时长 ≈ 字节数 ÷ 码率(25kbps÷8)，限 1~60 秒
                unsigned int dur = (unsigned int)MAX(1, MIN(60, (double)(silk.length - 9) / (25000.0 / 8)));
                NSString *to = WCVCurrentChatUser(self);
                NSMutableString *log = [NSMutableString string];
                BOOL ok = to.length > 0;
                if (!ok) {
                    [log appendString:@"❌ 拿不到当前聊天对象 (m_nsChatUsr)"];
                } else {
                    ok = WCVTrySendVoice(silk, to, dur, log);
                }
                NSString *msg = ok ? [NSString stringWithFormat:@"✅ 已发送 %.1f 秒克隆语音\n\n%@", (double)dur, log]
                                   : log;
                [self wcv_replaceHud:hud message:msg];
            });
        });
    }];
}

%new
- (void)wcv_testAPI {
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:nil
                            message:@"⏳ 正在查询…" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *wait = [UIAlertAction actionWithTitle:@"连接中…" style:UIAlertActionStyleDefault handler:nil];
    wait.enabled = NO;
    [hud addAction:wait];
    [self presentViewController:hud animated:YES completion:nil];
    [[FAVoiceAPI shared] creditWithCompletion:^(NSDictionary *json, NSError *error) {
        NSString *msg = error ? [NSString stringWithFormat:@"❌ %@", error.localizedDescription]
                              : [NSString stringWithFormat:@"✅ 连接正常\n%@", json ?: @""];
        [self wcv_replaceHud:hud message:msg];
    }];
}

%new
- (void)wcv_openSettings {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Fish Audio 配置"
                            message:@"API Key 在 fish.audio 后台生成；声音模型 ID 在克隆完成后获得"
                            preferredStyle:UIAlertControllerStyleAlert];
    WCPrefsManager *prefs = [WCPrefsManager shared];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"API Key";
        tf.text = prefs.apiKey;
        tf.secureTextEntry = YES;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"声音模型 ID (reference_id)";
        tf.text = prefs.modelId;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"引擎型号 (s2.1-pro-free=免费)";
        tf.text = prefs.ttsModel ?: @"s2.1-pro-free";
        tf.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        prefs.apiKey = alert.textFields[0].text ?: @"";
        prefs.modelId = alert.textFields[1].text ?: @"";
        NSString *m = alert.textFields[2].text ?: @"";
        prefs.ttsModel = m.length > 0 ? m : @"s2.1-pro-free";
        [prefs save];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)wcv_debugProbe {
    NSMutableString *report = [NSMutableString stringWithString:@"【本版微信可用方法】\n"];
    for (NSString *clsName in @[@"CMessageMgr", @"BaseMsgContentViewController", @"CMessageWrap"]) {
        Class cls = NSClassFromString(clsName);
        if (!cls) { [report appendFormat:@"%@ 不存在\n", clsName]; continue; }
        [report appendFormat:@"\n◆ %@\n", clsName];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            NSRange r1 = [selName rangeOfString:@"oice" options:NSCaseInsensitiveSearch];
            NSRange r2 = [selName rangeOfString:@"sg" options:NSCaseInsensitiveSearch];
            NSRange r3 = [selName rangeOfString:@"ocal" options:NSCaseInsensitiveSearch];
            if (r1.location != NSNotFound || r2.location != NSNotFound || r3.location != NSNotFound) {
                [report appendFormat:@"  - %@\n", selName];
            }
        }
        free(methods);
    }
    // 当前聊天页对象的所有字符串字段（用于定位 wxid 存在哪个属性里）
    [report appendString:@"\n【当前聊天页字段】\n"];
    Class c = [self class];
    while (c && report.length < 6000) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(ivars[i]);
            if (!t || t[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(self, ivars[i]); } @catch (NSException *e) { continue; }
            if ([v isKindOfClass:NSString.class]) {
                NSString *s = (NSString *)v;
                if (s.length > 0 && s.length < 80 && [s rangeOfString:@"\n"].location == NSNotFound) {
                    [report appendFormat:@"  %s = %@\n", ivar_getName(ivars[i]), s];
                }
            }
        }
        free(ivars);
        c = class_getSuperclass(c);
    }
    UIPasteboard.generalPasteboard.string = report;
    NSString *preview = report.length > 900 ? [[report substringToIndex:900] stringByAppendingString:@"…(完整内容已复制到剪贴板)"] : report;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已复制到剪贴板"
                            message:preview preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

%end

%ctor {
    NSLog(@"[WCVoiceClone] loaded 🎤");
    WCVRuntimeHookChatVCs();  // 自动适配各版本微信的聊天页类名
    // 自检横幅：dylib 若被成功注入，开微信约 4 秒后顶部显示一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (!w) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIWindow *w2 = [UIApplication sharedApplication].keyWindow;
                if (w2) WCVShowBanner(w2);
            });
            return;
        }
        WCVShowBanner(w);
    });
}
