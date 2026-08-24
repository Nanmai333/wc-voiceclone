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

// 当前聊天对象的 wxid
static NSString *WCVCurrentChatUser(UIViewController *vc) {
    for (NSString *key in @[@"m_nsChatUsr", @"m_nsToUsr"]) {
        id v = nil;
        @try { v = [vc valueForKey:key]; } @catch (NSException *e) {}
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) return v;
    }
    return nil;
}

// 自己的 wxid
static NSString *WCVOwnWxId(void) {
    Class mmCenter = NSClassFromString(@"MMServiceCenter");
    if (!mmCenter) return nil;
    id center = [mmCenter performSelector:NSSelectorFromString(@"defaultCenter")];
    if (!center) return nil;
    for (NSString *svcName in @[@"CAccountMgr", @"CContactMgr"]) {
        Class svcClass = NSClassFromString(svcName);
        if (!svcClass) continue;
        id mgr = nil;
        @try { mgr = [center performSelector:NSSelectorFromString(@"getService:") withObject:svcClass]; }
        @catch (NSException *e) {}
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

// 发送语音消息：多版本兼容尝试
static BOOL WCVTrySendVoice(NSData *silk, NSString *toUser, unsigned int durationSec, NSMutableString *log) {
    Class msgWrapClass = NSClassFromString(@"CMessageWrap");
    Class msgMgrClass  = NSClassFromString(@"CMessageMgr");
    Class mmCenter     = NSClassFromString(@"MMServiceCenter");
    if (!msgWrapClass || !msgMgrClass || !mmCenter) {
        [log appendFormat:@"缺少核心类 (%@/%@/%@)\n", msgWrapClass, msgMgrClass, mmCenter];
        return NO;
    }
    id center = [mmCenter performSelector:NSSelectorFromString(@"defaultCenter")];
    id mgr = [center performSelector:NSSelectorFromString(@"getService:") withObject:msgMgrClass];
    if (!mgr) { [log appendString:@"拿不到 CMessageMgr 服务\n"]; return NO; }

    id msg = [[msgWrapClass alloc] init];
    WCVSafeSet(msg, @[@"m_uiMessageType", @"m_iMessageType"], @34);          // 34=语音
    WCVSafeSet(msg, @[@"m_nsFromUsr"], WCVOwnWxId() ?: @"");
    WCVSafeSet(msg, @[@"m_nsToUsr", @"m_nsChatUsr"], toUser);
    WCVSafeSet(msg, @[@"m_nsContent"], @"[语音]");
    WCVSafeSet(msg, @[@"m_dtVoice", @"nativeVoiceData"], silk);
    WCVSafeSet(msg, @[@"m_nVoiceTime", @"m_nTotalLen", @"m_uiVoiceTime"], @(durationSec));
    WCVSafeSet(msg, @[@"m_uiCreateTime"], @((unsigned int)[NSDate date].timeIntervalSince1970));

    NSArray<NSString *> *candidates = @[
        @"AddLocalMsg:MsgWrap:",
        @"AddLocalMsg:",
        @"AddMsg:MsgWrap:",
        @"AddMsg:",
        @"AddSendingMsg:",
        @"AddSendingMsg:MsgWrap:",
        @"MessageReturn:MessageInfo:",
    ];
    for (NSString *name in candidates) {
        SEL sel = NSSelectorFromString(name);
        if (![mgr respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
        if (!sig) continue;
        NSInteger nArgs = sig.numberOfArguments - 2; // 真实参数个数
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:mgr];
            [inv setSelector:sel];
            if (nArgs == 1) {
                [inv setArgument:&msg atIndex:2];
            } else if (nArgs == 2) {
                [inv setArgument:&toUser atIndex:2];
                [inv setArgument:&msg atIndex:3];
            } else if (nArgs == 3) {
                [inv setArgument:&toUser atIndex:2];
                [inv setArgument:&msg atIndex:3];
                unsigned int d = durationSec;
                [inv setArgument:&d atIndex:4];
            } else {
                continue;
            }
            [inv invoke];
            [log appendFormat:@"✅ 通过 [%@ %@] 调用成功\n", msgMgrClass, name];
            return YES;
        } @catch (NSException *e) {
            [log appendFormat:@"⚠️ %@ 抛异常: %@\n", name, e.reason];
        }
    }
    [log appendString:@"❌ 候选发送方法都不可用。点悬浮球 → 🐞调试，探测本版微信的真实方法名。\n"];
    return NO;
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
                            message:@"⏳ 正在合成语音…" preferredStyle:UIAlertControllerStyleAlert];
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
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *silkErr = nil;
            NSData *silk = [WCSilkBridge silkFromPCM:data sampleRateHz:24000 error:&silkErr];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!silk) {
                    [self wcv_replaceHud:hud message:[NSString stringWithFormat:@"❌ SILK 编码失败：%@", silkErr.localizedDescription]];
                    return;
                }
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
