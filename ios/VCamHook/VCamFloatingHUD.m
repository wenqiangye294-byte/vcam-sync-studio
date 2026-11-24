#import "VCamFloatingHUD.h"
#import "VCamQueueStore.h"

@interface VCamFloatingHUD ()
@property (nonatomic, strong) UIView *pillView;
@property (nonatomic, strong) UIButton *statusButton;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *nextButton;
@end

@implementation VCamFloatingHUD

+ (instancetype)sharedHUD {
    static VCamFloatingHUD *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamFloatingHUD alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleQueueChange:)
                                                     name:VCamQueueStoreDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleQueueChange:(NSNotification *)note {
    (void)note;
    [self attachAndRefresh];
}

- (nullable UIWindow *)findKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *win in ws.windows) {
                    if (win.isKeyWindow) return win;
                }
                if (ws.windows.firstObject) return ws.windows.firstObject;
            }
        }
    }
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if (win.isKeyWindow) return win;
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (void)ensureViewsBuilt {
    if (self.pillView) return;

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(16, 56, 224, 34)];
    pill.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.84];
    pill.layer.cornerRadius = 17.0;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
    pill.clipsToBounds = YES;

    UIButton *statusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    statusBtn.frame = CGRectMake(8, 5, 24, 24);
    statusBtn.layer.cornerRadius = 12.0;
    statusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    [statusBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [statusBtn addTarget:self action:@selector(onTapStatus) forControlEvents:UIControlEventTouchUpInside];

    UIButton *prevBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    prevBtn.frame = CGRectMake(34, 2, 28, 30);
    [prevBtn setTitle:@"‹" forState:UIControlStateNormal];
    [prevBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    prevBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [prevBtn addTarget:self action:@selector(onTapPrev) forControlEvents:UIControlEventTouchUpInside];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(62, 2, 128, 30)];
    label.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightSemibold];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;

    UIButton *nextBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nextBtn.frame = CGRectMake(190, 2, 28, 30);
    [nextBtn setTitle:@"›" forState:UIControlStateNormal];
    [nextBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nextBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [nextBtn addTarget:self action:@selector(onTapNext) forControlEvents:UIControlEventTouchUpInside];

    [pill addSubview:statusBtn];
    [pill addSubview:prevBtn];
    [pill addSubview:label];
    [pill addSubview:nextBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [pill addGestureRecognizer:pan];

    self.pillView = pill;
    self.statusButton = statusBtn;
    self.prevButton = prevBtn;
    self.titleLabel = label;
    self.nextButton = nextBtn;
}

- (void)attachAndRefresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureViewsBuilt];
        VCamQueueStore *store = [VCamQueueStore sharedStore];
        [store reloadIfNeeded];

        UIWindow *win = [self findKeyWindow];
        if (!win) return;

        if (self.pillView.superview != win) {
            [win addSubview:self.pillView];
        }
        [win bringSubviewToFront:self.pillView];

        BOOL hasAny = (store.photoCount > 0 || store.videoCount > 0);
        self.pillView.hidden = !(store.showHUD && hasAny);

        if (store.isEnabled) {
            self.statusButton.backgroundColor = [UIColor colorWithRed:0.06 green:0.72 blue:0.51 alpha:1.0];
            [self.statusButton setTitle:@"开" forState:UIControlStateNormal];
        } else {
            self.statusButton.backgroundColor = [UIColor colorWithWhite:0.45 alpha:1.0];
            [self.statusButton setTitle:@"停" forState:UIControlStateNormal];
        }

        NSString *pText = store.photoCount > 0
            ? [NSString stringWithFormat:@"图%ld/%ld", (long)(store.photoCursor + 1), (long)store.photoCount]
            : @"图0";
        NSString *vText = store.isRecordingVideo
            ? @"录制中"
            : (store.videoCount > 0 ? [NSString stringWithFormat:@"视%ld", (long)store.videoCount] : @"无视");
        self.titleLabel.text = [NSString stringWithFormat:@"%@ · %@", pText, vText];
    });
}

- (void)onTapStatus {
    [[VCamQueueStore sharedStore] toggleEnabled];
}

- (void)onTapPrev {
    [[VCamQueueStore sharedStore] stepPhotoCursorBy:-1];
}

- (void)onTapNext {
    [[VCamQueueStore sharedStore] stepPhotoCursorBy:1];
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.pillView.superview;
    if (!superview) return;
    CGPoint trans = [pan translationInView:superview];
    CGPoint c = self.pillView.center;
    c.x += trans.x;
    c.y += trans.y;
    CGFloat halfW = self.pillView.bounds.size.width * 0.5;
    CGFloat halfH = self.pillView.bounds.size.height * 0.5;
    c.x = MAX(halfW + 6, MIN(superview.bounds.size.width - halfW - 6, c.x));
    c.y = MAX(halfH + 24, MIN(superview.bounds.size.height - halfH - 20, c.y));
    self.pillView.center = c;
    [pan setTranslation:CGPointZero inView:superview];
}

@end
