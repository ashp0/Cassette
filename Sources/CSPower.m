#import "CSPower.h"
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <notify.h>
#include <stdlib.h>

static CSPowerSource sOverride;
static BOOL          sOverrideOn;

void CSSetPowerSourceOverride(CSPowerSource source, BOOL enabled)
{
    sOverride   = source;
    sOverrideOn = enabled;
}

CSPowerSource CSPowerSourceFromString(NSString *s)
{
    if (![s isKindOfClass:[NSString class]]) return CSPowerUnknown;
    NSString *v = [[s stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([v isEqualToString:@"ac power"] || [v isEqualToString:@"ac"] ||
        [v isEqualToString:@"acpower"]  || [v isEqualToString:@"mains"])
        return CSPowerAC;
    if ([v isEqualToString:@"battery power"] || [v isEqualToString:@"battery"] ||
        [v isEqualToString:@"batterypower"]  || [v isEqualToString:@"batt"])
        return CSPowerBattery;
    return CSPowerUnknown;
}

// The command-line pin, read once. The environment wins over defaults so that a
// test harness can set it without touching the user's preferences. "auto", or
// anything unrecognised, leaves the machine to answer for itself.
static void CSApplyPinnedPowerSourceOnce(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (sOverrideOn) return;
        NSString *v = nil;
        const char *env = getenv("CASSETTE_POWER");
        if (env && env[0]) v = [NSString stringWithUTF8String:env];
        if ([v length] == 0)
            v = [[NSUserDefaults standardUserDefaults] stringForKey:@"CSPowerState"];
        CSPowerSource pinned = CSPowerSourceFromString(v);
        if (pinned != CSPowerUnknown) CSSetPowerSourceOverride(pinned, YES);
    });
}

CSPowerSource CSCurrentPowerSource(void)
{
    CSApplyPinnedPowerSourceOnce();
    if (sOverrideOn) return sOverride;

    CSPowerSource result = CSPowerUnknown;
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (blob) {
        // A desktop with no battery at all reports "AC Power" here, which is
        // the answer wanted: a Mac Pro is always on the wall.
        CFStringRef kind = IOPSGetProvidingPowerSourceType(blob);
        if (kind) result = CSPowerSourceFromString((NSString *)kind);
        CFRelease(blob);
    }
    return result;
}

int CSObservePowerSource(dispatch_block_t handler)
{
    if (!handler) return -1;
    int token = -1;
    dispatch_block_t copy = [[handler copy] autorelease];
    uint32_t status = notify_register_dispatch(kIOPSNotifyPowerSource, &token,
                                               dispatch_get_main_queue(),
                                               ^(int t) { (void)t; copy(); });
    return (status == NOTIFY_STATUS_OK) ? token : -1;
}

void CSStopObservingPowerSource(int token)
{
    if (token >= 0) notify_cancel(token);
}

BOOL CSReelsShouldSpin(CSPowerSource power, CSUIState s)
{
    if (!s.playing || !s.windowOpen) return NO;
    if (power == CSPowerAC) return YES;
    return s.appActive && s.windowOnScreen;
}
