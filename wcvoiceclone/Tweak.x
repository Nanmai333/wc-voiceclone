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

static BOOL WCVCaptureArmedOnce = YES;   // 启动后首次遇到真实录音时捕获字段
static double WCVOwnSendUntilTs = 0;      // 我们自己发送后的静默截止时间戳
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
static BOOL WCVTrySendVoice(NSData *silk, NSString *toUser, unsigned int durationMs, NSMutableString *log) {
    Class msgWrapClass = NSClassFromString(@"CMessageWrap");
    Class mgrClass     = NSClassFromString(@"CMessageMgr");
    if (!msgWrapClass || !mgrClass) {
        [log appendString:@"缺少核心类 CMessageWrap/CMessageMgr\n"];
        return NO;
    }
    @try {
    NSString *fromUser = WCVOwnWxId() ?: @"";

    // 1. 官方初始化器构造语音消息
    id msg = nil;
    SEL initSel = NSSelectorFromString(@"initWithMsgType:nsFromUsr:");
    if ([msgWrapClass instancesRespondToSelector:initSel]) {
        NSMethodSignature *sig = [msgWrapClass instanceMethodSignatureForSelector:initSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        id alloced = [msgWrapClass alloc];
        long long msgType = 34;
        [inv setTarget:alloced];
        [inv setSelector:initSel];
        [inv setArgument:&msgType atIndex:2];
        [inv setArgument:&fromUser atIndex:3];
        [inv invoke];
        void *retObj = NULL;
        [inv getReturnValue:&retObj];
        msg = (__bridge id)retObj;
    }
    if (!msg) msg = [[msgWrapClass alloc] init];

    // 2. 关键字段 —— 严格对照真机捕获的原生模板
    //    模板: status=1 downloadStatus=1 msgSource="" 
    //    content 是 XML: <msg><voicemsg voicelength="ms" voiceformat="4" forwardflag="0"/></msg>
    WCVSafeSet(msg, @[@"m_uiMessageType", @"m_iMessageType"], @34);
    WCVSafeSet(msg, @[@"m_nsFromUsr"], fromUser);
    WCVSafeSet(msg, @[@"m_nsToUsr", @"m_nsTalker", @"m_nsChatUsr"], toUser);
    NSString *contentXml = [NSString stringWithFormat:
        @"<msg><voicemsg voicelength=\"%u\" voiceformat=\"4\" forwardflag=\"0\" /></msg>", durationMs];
    WCVSafeSet(msg, @[@"m_nsContent"], contentXml);
    WCVSafeSet(msg, @[@"m_uiStatus"], @1);                 // 模板值
    WCVSafeSet(msg, @[@"m_uiDownloadStatus"], @1);         // 模板值
    WCVSafeSet(msg, @[@"m_uiVoiceFormat", @"m_voiceFormat", @"m_cVoiceFormat"], @4);
    WCVSafeSet(msg, @[@"m_uiVoiceEndFlag"], @1);
    WCVSafeSet(msg, @[@"m_uiVoiceTime"], @(durationMs));   // 上传管理器可能读取
    WCVOwnSendUntilTs = [NSDate date].timeIntervalSince1970 + 6;
    WCVSafeSet(msg, @[@"m_dtVoice", @"nativeVoiceData"], silk);
    WCVSafeSet(msg, @[@"m_uiCreateTime"], @((unsigned int)[NSDate date].timeIntervalSince1970));

    // 2.5 附加语音扩展信息对象（原生消息自带）
    Class extCls = NSClassFromString(@"CExtendInfoOfVoiceMsg");
    if (extCls) {
        id ext = [[extCls alloc] init];
        if (ext) WCVSafeSet(msg, @[@"m_extendInfoWithMsgType"], ext);
    }

    // 3. 入库（WCVoice 验证流程第一步）：本地出现气泡并分配 LocalID
    BOOL inserted = NO;
    id mgr = WCVGetService(mgrClass);
    if (mgr) {
        SEL addLocal = NSSelectorFromString(@"AddLocalMsg:MsgWrap:");
        NSMethodSignature *sig = [mgr methodSignatureForSelector:addLocal];
        if ([mgr respondsToSelector:addLocal] && sig && sig.numberOfArguments - 2 == 2) {
            const char *t2 = [sig getArgumentTypeAtIndex:2];
            const char *t3 = [sig getArgumentTypeAtIndex:3];
            if (t2 && t2[0] == '@' && t3 && t3[0] == '@') {
                @try {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:mgr];
                    [inv setSelector:addLocal];
                    [inv setArgument:&toUser atIndex:2];
                    [inv setArgument:&msg atIndex:3];
                    [inv invoke];
                    inserted = YES;
                    [log appendString:@"✅ AddLocalMsg 已入库\n"];
                } @catch (NSException *e) {
                    [log appendFormat:@"⚠️ AddLocalMsg 异常: %@\n", e.reason];
                }
            }
        } else {
            [log appendString:@"⚠️ AddLocalMsg:MsgWrap: 不可用\n"];
        }
    } else {
        [log appendString:@"⚠️ 拿不到 CMessageMgr\n"];
    }

    // 4. 读取入库分配的 LocalID
    unsigned int localID = 0;
    {
        id v = nil;
        @try { v = [msg valueForKey:@"m_uiMesLocalID"]; } @catch (NSException *e) {}
        if ([v isKindOfClass:NSString.class]) localID = (unsigned int)[(NSString *)v intValue];
        else if ([v isKindOfClass:NSNumber.class]) localID = [(NSNumber *)v unsignedIntValue];
    }
    [log appendFormat:@"✓ LocalID=%u 时长=%ums\n", localID, durationMs];

    // 5. 写 silk 到微信期望的音频路径
    SEL gp = NSSelectorFromString(@"getPathOfMsgImg:");
    if ([msgWrapClass respondsToSelector:gp]) {
        @try {
            NSString *p = [msgWrapClass performSelector:gp withObject:msg];
            if ([p isKindOfClass:NSString.class]) {
                p = [(NSString *)p stringByReplacingOccurrencesOfString:@"Img" withString:@"Audio"];
                p = [(NSString *)p stringByReplacingOccurrencesOfString:@".pic" withString:@".aud"];
                [[NSFileManager defaultManager]
                    createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                          withIntermediateDirectories:YES attributes:nil error:nil];
                [silk writeToFile:p atomically:YES];
                [log appendFormat:@"✓ 音频文件已写入 (%.1f KB)\n", silk.length / 1024.0];
            }
        } @catch (NSException *e) {
            [log appendFormat:@"- 写文件跳过: %@\n", e.reason];
        }
    }

    // 6. 触发上传发送（WCVoice 同款通道）
    Class senderClass = NSClassFromString(@"AudioSender");
    id sender = senderClass ? WCVGetService(senderClass) : nil;
    if (sender) {
        SEL resend = NSSelectorFromString(@"ResendVoiceMsg:MsgWrap:");
        NSMethodSignature *sig = [sender methodSignatureForSelector:resend];
        if ([sender respondsToSelector:resend] && sig && sig.numberOfArguments - 2 == 2) {
            const char *t2 = [sig getArgumentTypeAtIndex:2];
            const char *t3 = [sig getArgumentTypeAtIndex:3];
            if (t2 && t2[0] == '@' && t3 && t3[0] == '@') {
                @try {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:sender];
                    [inv setSelector:resend];
                    [inv setArgument:&toUser atIndex:2];
                    [inv setArgument:&msg atIndex:3];
                    [inv invoke];
                    [log appendString:@"✅ AudioSender ResendVoiceMsg 已触发上传\n"];
                    return YES;
                } @catch (NSException *e) {
                    [log appendFormat:@"⚠️ ResendVoiceMsg 异常: %@\n", e.reason];
                }
            }
        } else {
            [log appendFormat:@"⚠️ AudioSender 无 ResendVoiceMsg 方法\n"];
        }
    } else {
        [log appendString:@"⚠️ AudioSender 服务不存在（新版微信可能改名）\n"];
    }

    // 7. 兜底：AddMsg 正式发送通道
    if (mgr) {
        SEL addMsg = NSSelectorFromString(@"AddMsg:MsgWrap:");
        NSMethodSignature *sig = [mgr methodSignatureForSelector:addMsg];
        if ([mgr respondsToSelector:addMsg] && sig && sig.numberOfArguments - 2 == 2) {
            const char *t2 = [sig getArgumentTypeAtIndex:2];
            const char *t3 = [sig getArgumentTypeAtIndex:3];
            if (t2 && t2[0] == '@' && t3 && t3[0] == '@') {
                @try {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:mgr];
                    [inv setSelector:addMsg];
                    [inv setArgument:&toUser atIndex:2];
                    [inv setArgument:&msg atIndex:3];
                    [inv invoke];
                    [log appendString:@"✅ AddMsg 兜底通道调用成功\n"];
                    return YES;
                } @catch (NSException *e) {
                    [log appendFormat:@"⚠️ AddMsg 异常: %@\n", e.reason];
                }
            }
        }
    }

    if (inserted) {
        [log appendString:@"◆ 消息已入库但上传未触发，气泡可能仅本地可见\n"];
        return YES;
    }
    [log appendString:@"❌ 发送失败。请用 🐞调试 导出后发我适配。\n"];
    return NO;
    } @catch (NSException *e) {
        [log appendFormat:@"⚠️ 发送过程异常: %@\n", e.reason];
        return NO;
    }
}

#pragma mark - 自检横幅 + 运行时适配不同微信版本的聊天类

static void WCVShowBannerText(UIWindow *window, NSString *text) {
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(20, 90, window.bounds.size.width - 40, 44)];
    banner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    banner.layer.cornerRadius = 12;
    banner.userInteractionEnabled = NO;
    UILabel *label = [[UILabel alloc] initWithFrame:banner.bounds];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:15];
    [banner addSubview:label];
    [window addSubview:banner];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [banner removeFromSuperview]; });
}

static void WCVShowBanner(UIWindow *window) {
    WCVShowBannerText(window, @"🎤 WCVoiceClone 已注入");
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
                // 精确时长：PCM 字节数 ÷ 2 = 采样数；24000Hz
                unsigned int durMs = (unsigned int)MAX(500, MIN(59000, (double)(data.length / 2) / 24.0));
                NSString *to = WCVCurrentChatUser(self);
                NSMutableString *log = [NSMutableString string];
                BOOL ok = to.length > 0;
                if (!ok) {
                    [log appendString:@"❌ 拿不到当前聊天对象"];
                } else {
                    ok = WCVTrySendVoice(silk, to, durMs, log);
                }
                NSString *msg = ok ? [NSString stringWithFormat:@"✅ 已发送 %.1f 秒克隆语音\n\n%@", durMs / 1000.0, log]
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

// 真实语音字段捕获：用户手动录一条语音时，把微信原生构造的字段值导出到剪贴板并弹窗
static void WCVCaptureFields(id wrap, UIViewController *host) {
    @try {
        NSNumber *type = nil;
        @try { type = [wrap valueForKey:@"m_uiMessageType"]; } @catch (NSException *e) {}
        if (![type isEqual:@34]) return;   // 只处理语音消息
        if (!WCVCaptureArmedOnce) return;
        if ([NSDate date].timeIntervalSince1970 < WCVOwnSendUntilTs) return;

        WCVCaptureArmedOnce = NO;
        NSMutableString *r = [NSMutableString stringWithString:@"【真实语音消息字段模板】\n"];
        NSArray<NSString *> *keys = @[
            @"m_uiMesLocalID", @"m_uiVoiceTime", @"m_nTotalLen", @"m_nVoiceTime",
            @"m_uiVoiceFormat", @"m_cVoiceFormat", @"m_uiStatus", @"m_uiDownloadStatus",
            @"m_uiCreateTime", @"m_nsMsgSource", @"m_nsFromUsr", @"m_nsToUsr",
            @"m_nsContent", @"m_bIsSender",
        ];
        for (NSString *k in keys) {
            id v = nil;
            @try { v = [wrap valueForKey:k]; } @catch (NSException *e2) { continue; }
            if (v == nil) { [r appendFormat:@"%@ = (nil)\n", k]; continue; }
            if ([v isKindOfClass:NSData.class]) {
                NSData *d = (NSData *)v;
                NSMutableString *hex = [NSMutableString string];
                const unsigned char *bytes = (const unsigned char *)d.bytes;
                for (NSUInteger i = 0; i < 12 && i < d.length; i++)
                    [hex appendFormat:@"%02x ", bytes[i]];
                [r appendFormat:@"%@ = NSData(%lu字节) 头: %@\n", k, (unsigned long)d.length, hex];
            } else {
                NSString *s = [NSString stringWithFormat:@"%@", v];
                if (s.length > 200) s = [[s substringToIndex:200] stringByAppendingString:@"…"];
                [r appendFormat:@"%@ = (%@) %@\n", k, NSStringFromClass([v class]), s];
            }
        }
        id ext = nil;
        @try { ext = [wrap valueForKey:@"m_extendInfoWithMsgType"]; } @catch (NSException *e3) {}
        [r appendFormat:@"extendInfo = %@\n", ext ?: @"(nil)"];

        UIPasteboard.generalPasteboard.string = r;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = host;
            if (!vc) {
                UIWindow *w = [UIApplication sharedApplication].keyWindow;
                vc = w.rootViewController;
            }
            if (vc) {
                UIAlertController *al = [UIAlertController alertControllerWithTitle:@"已捕获真实语音字段"
                                      message:r.length > 600 ? [[r substringToIndex:600] stringByAppendingString:@"…(完整在剪贴板)"] : r
                                      preferredStyle:UIAlertControllerStyleAlert];
                [al addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [vc presentViewController:al animated:YES completion:nil];
            }
        });
    } @catch (NSException *e) {}
}

// 多个提交点都挂钩（不同微信版本实际走的入口不同）
%hook CMessageMgr
- (void)AddLocalMsg:(id)arg1 MsgWrap:(id)arg2 {
    %orig;
    @try { WCVCaptureFields(arg2, nil); } @catch (NSException *e) {}
}
- (void)AddMsg:(id)arg1 MsgWrap:(id)arg2 {
    %orig;
    @try { WCVCaptureFields(arg2, nil); } @catch (NSException *e) {}
}
- (void)AsyncOnAddMsgForSession:(id)arg1 MsgWrap:(id)arg2 {
    %orig;
    @try { WCVCaptureFields(arg2, nil); } @catch (NSException *e) {}
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
