#import "../shared/VCamProtocol.h"
#import "VCamAVFoundationHook.h"
#import "VCamFloatingHUD.h"
#import "VCamQueueStore.h"
#import <UIKit/UIKit.h>

__attribute__((constructor))
static void vcam_hook_entry(void) {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (!bundleID || bundleID.length == 0) {
            return;
        }
        // Never hook our own companion app (whose QR scanner needs the real camera)
        if ([bundleID isEqualToString:VCamCompanionBundleID]) {
            return;
        }
        // Never hook SpringBoard / backboardd / WebKit helper processes
        if ([bundleID isEqualToString:@"com.apple.springboard"] ||
            [bundleID isEqualToString:@"com.apple.backboardd"] ||
            [bundleID hasPrefix:@"com.apple.WebKit"]) {
            return;
        }

        [VCamQueueStore sharedStore];
        [VCamAVFoundationHook installHooks];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            (void)note;
            [[VCamQueueStore sharedStore] reloadIfNeeded];
            [[VCamFloatingHUD sharedHUD] attachAndRefresh];
        }];
    }
}
