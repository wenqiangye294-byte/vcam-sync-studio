#import "AppDelegate.h"
#import "AppContainerMirror.h"
#import "LocalBridgeServer.h"
#import "MainViewController.h"
#import "SyncManager.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    MainViewController *mainVC = [[MainViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:mainVC];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    [LocalBridgeServer sharedServer].onHookEvent = ^(NSDictionary *eventDict) {
        [[SyncManager sharedManager] handleHookEvent:eventDict];
    };
    [[LocalBridgeServer sharedServer] start];

    [[AppContainerMirror sharedMirror] startWatchingHookStateChangesWithHandler:^(NSDictionary *stateDict) {
        [[SyncManager sharedManager] handleHookEvent:@{
            @"event_type": @"cursor_changed",
            @"product_id": stateDict[@"product_id"] ?: @"",
            @"photo_cursor": stateDict[@"photo_cursor"] ?: @0,
            @"video_cursor": stateDict[@"video_cursor"] ?: @0,
            @"sync_revision": stateDict[@"revision"] ?: @0
        }];
    }];

    [[SyncManager sharedManager] connectIfConfigured];
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    (void)app;
    (void)options;
    if (url.absoluteString.length > 0) {
        return [[SyncManager sharedManager] parseAndApplyPairingURL:url.absoluteString];
    }
    return NO;
}

@end
