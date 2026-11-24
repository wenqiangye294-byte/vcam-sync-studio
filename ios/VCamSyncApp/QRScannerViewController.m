#import "QRScannerViewController.h"
#import <AVFoundation/AVFoundation.h>

@interface QRScannerViewController () <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) BOOL handled;
@end

@implementation QRScannerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"扫码配对电脑";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(onCancel)];

    [self checkAndStartCamera];
}

- (void)onCancel {
    [self stopSession];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)checkAndStartCamera {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        [self setupCameraSession];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) {
                    [self setupCameraSession];
                } else {
                    [self showNoCameraAlert];
                }
            });
        }];
    } else {
        [self showNoCameraAlert];
    }
}

- (void)showNoCameraAlert {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"需要相机权限"
                                                                message:@"请在系统设置中允许 VCamSync 使用相机以扫描电脑端配对二维码。"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)setupCameraSession {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) return;
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
    if (!input || err) return;

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if ([session canAddInput:input]) {
        [session addInput:input];
    }

    AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
    if ([session canAddOutput:output]) {
        [session addOutput:output];
        [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        if ([output.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) {
            output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
        }
    }

    AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
    preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    preview.frame = self.view.bounds;
    [self.view.layer addSublayer:preview];

    [self buildOverlayGuide];

    self.captureSession = session;
    self.previewLayer = preview;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [session startRunning];
    });
}

- (void)buildOverlayGuide {
    CGFloat size = 240.0;
    CGRect boxRect = CGRectMake((self.view.bounds.size.width - size) * 0.5,
                                (self.view.bounds.size.height - size) * 0.45,
                                size, size);
    UIView *box = [[UIView alloc] initWithFrame:boxRect];
    box.layer.borderColor = [UIColor colorWithRed:0.15 green:0.55 blue:1.0 alpha:1.0].CGColor;
    box.layer.borderWidth = 2.5;
    box.layer.cornerRadius = 14.0;
    box.backgroundColor = [UIColor clearColor];
    [self.view addSubview:box];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(24, CGRectGetMaxY(boxRect) + 20, self.view.bounds.size.width - 48, 40)];
    hint.text = @"将取景框对准电脑工作台右侧的配对二维码";
    hint.textColor = [UIColor whiteColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    hint.layer.cornerRadius = 8;
    hint.clipsToBounds = YES;
    [self.view addSubview:hint];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.previewLayer.frame = self.view.bounds;
}

- (void)stopSession {
    if (self.captureSession && self.captureSession.isRunning) {
        AVCaptureSession *s = self.captureSession;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [s stopRunning];
        });
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;
    if (self.handled) return;
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            NSString *val = ((AVMetadataMachineReadableCodeObject *)obj).stringValue;
            if (val.length > 0 && [val hasPrefix:@"vcamsync://"]) {
                self.handled = YES;
                [self stopSession];
                [self dismissViewControllerAnimated:YES completion:^{
                    if (self.onScanCode) self.onScanCode(val);
                }];
                return;
            }
        }
    }
}

@end
