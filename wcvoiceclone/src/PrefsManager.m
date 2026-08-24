#import "PrefsManager.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString * const kDomain = @"com.local.wcvoiceclone";

static id _read(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
}

@implementation WCPrefsManager

+ (instancetype)shared {
    static WCPrefsManager *mgr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mgr = [WCPrefsManager new];
        [mgr reload];
    });
    return mgr;
}

- (void)reload {
    _apiKey    = [_read(@"apiKey") isKindOfClass:NSString.class] ? _read(@"apiKey") : @"";
    _modelId   = [_read(@"modelId") isKindOfClass:NSString.class] ? _read(@"modelId") : @"";
    id fb      = _read(@"floatBallEnabled");
    _floatBallEnabled = fb ? [fb boolValue] : YES;
}

- (void)save {
    NSDictionary *all = @{@"apiKey": _apiKey ?: @"",
                          @"modelId": _modelId ?: @"",
                          @"floatBallEnabled": @(_floatBallEnabled)};
    [all enumerateKeysAndObjectsUsingBlock:^(NSString *key, id val, BOOL *stop) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFTypeRef)val, (__bridge CFStringRef)kDomain);
    }];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
}

- (BOOL)isConfigured {
    return _apiKey.length > 8 && _modelId.length > 4;
}

@end
