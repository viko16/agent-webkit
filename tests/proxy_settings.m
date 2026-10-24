// Test-only CFNetwork boundary injection. Never changes SystemConfiguration or user settings.
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>

static CFDictionaryRef fixtureProxySettings(void) {
    @autoreleasepool {
        const char *path = getenv("AW_TEST_PROXY_SETTINGS");
        if (!path) return CFNetworkCopySystemProxySettings();
        NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
        id settings = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        // Fail closed if the test input disappears or is malformed.
        if (![settings isKindOfClass:[NSDictionary class]]) settings = @{@"HTTPEnable": @1};
        return (CFDictionaryRef)CFRetain((__bridge CFDictionaryRef)settings);
    }
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } proxyInterpose = {
    (const void *)fixtureProxySettings, (const void *)CFNetworkCopySystemProxySettings
};
