#import "VCamAVFoundationHook.h"
#import "VCamMediaRenderer.h"
#import "VCamQueueStore.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *kVCamVideoProxyKey = &kVCamVideoProxyKey;
static const void *kVCamPhotoDataKey = &kVCamPhotoDataKey;
static const void *kVCamPhotoUIImageKey = &kVCamPhotoUIImageKey;
static const void *kVCamMovieProxyKey = &kVCamMovieProxyKey;
static const void *kVCamWriterStartTimeKey = &kVCamWriterStartTimeKey;
static const void *kVCamWriterRecordingActiveKey = &kVCamWriterRecordingActiveKey;

static void vcam_swizzleMethod(Class cls, SEL origSel, SEL swizSel, BOOL isClassMethod) {
    if (!cls || !origSel || !swizSel) return;
    Class targetCls = isClassMethod ? object_getClass(cls) : cls;
    Method origMethod = class_getInstanceMethod(targetCls, origSel);
    Method swizMethod = class_getInstanceMethod(targetCls, swizSel);
    if (!origMethod || !swizMethod) return;

    if (class_addMethod(targetCls, origSel, method_getImplementation(swizMethod), method_getTypeEncoding(swizMethod))) {
        class_replaceMethod(targetCls, swizSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

#pragma mark - Delegate Proxies

@interface VCamVideoDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> target;
@end

@implementation VCamVideoDelegateProxy

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) {
        return YES;
    }
    if (aSelector == @selector(captureOutput:didDropSampleBuffer:fromConnection:)) {
        return [self.target respondsToSelector:aSelector];
    }
    return [super respondsToSelector:aSelector] || [self.target respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id t = self.target;
    if ([t respondsToSelector:aSelector]) {
        return t;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if (!target || ![target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        return;
    }

    CMSampleBufferRef replacement = [[VCamMediaRenderer sharedRenderer] createReplacementSampleBufferFromOriginal:sampleBuffer];
    if (replacement) {
        [target captureOutput:output didOutputSampleBuffer:replacement fromConnection:connection];
        CFRelease(replacement);
    } else {
        [target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if (target && [target respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [target captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

@interface VCamPhotoDelegateProxy : NSObject <AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id<AVCapturePhotoCaptureDelegate> target;
@end

@implementation VCamPhotoDelegateProxy

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didFinishProcessingPhoto:error:) ||
        aSelector == @selector(captureOutput:didFinishCaptureForResolvedSettings:error:)) {
        return [self.target respondsToSelector:aSelector];
    }
    return [super respondsToSelector:aSelector] || [self.target respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id t = self.target;
    if ([t respondsToSelector:aSelector]) {
        return t;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
                error:(NSError *)error {
    if (!error && photo) {
        VCamQueueStore *store = [VCamQueueStore sharedStore];
        NSData *jpegData = [store currentPhotoJPEGData];
        if (store.isEnabled && jpegData.length > 0) {
            objc_setAssociatedObject(photo, kVCamPhotoDataKey, jpegData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [store advancePhotoCursorWithReason:@"photo_captured"];
        }
    }
    if ([self.target respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        [self.target captureOutput:output didFinishProcessingPhoto:photo error:error];
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
                error:(NSError *)error {
    if ([self.target respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
        [self.target captureOutput:output didFinishCaptureForResolvedSettings:resolvedSettings error:error];
    }
}

@end

@interface VCamMovieDelegateProxy : NSObject <AVCaptureFileOutputRecordingDelegate>
@property (nonatomic, strong) id<AVCaptureFileOutputRecordingDelegate> target;
@property (nonatomic, assign) CFTimeInterval startTime;
@end

@implementation VCamMovieDelegateProxy

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:) ||
        aSelector == @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)) {
        return YES;
    }
    return [super respondsToSelector:aSelector] || [self.target respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id t = self.target;
    if ([t respondsToSelector:aSelector]) {
        return t;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (void)captureOutput:(AVCaptureFileOutput *)output
didStartRecordingToOutputFileAtURL:(NSURL *)fileURL
      fromConnections:(NSArray<AVCaptureConnection *> *)connections {
    if ([self.target respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:)]) {
        [self.target captureOutput:output didStartRecordingToOutputFileAtURL:fileURL fromConnections:connections];
    }
}

- (void)captureOutput:(AVCaptureFileOutput *)output
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
      fromConnections:(NSArray<AVCaptureConnection *> *)connections
                error:(NSError *)error {
    VCamQueueStore *store = [VCamQueueStore sharedStore];
    BOOL wasRecording = store.isRecordingVideo;
    store.isRecordingVideo = NO;
    [[VCamMediaRenderer sharedRenderer] endVideoPlayback];

    double elapsed = MAX(0.1, CACurrentMediaTime() - self.startTime);
    CMTime recDuration = CMTimeMakeWithSeconds(elapsed, 600);

    if (wasRecording && store.isEnabled && [store currentVideoURL] != nil) {
        [[VCamMediaRenderer sharedRenderer] replaceRecordedVideoAtURL:outputFileURL
                                                     recordedDuration:recDuration
                                                                 mode:store.videoReplaceMode
                                                           completion:^(BOOL replaced) {
            if (replaced || [store.videoReplaceMode isEqualToString:@"frames"]) {
                [store advanceVideoCursorWithReason:@"video_recorded"];
            }
            if ([self.target respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)]) {
                [self.target captureOutput:output didFinishRecordingToOutputFileAtURL:outputFileURL fromConnections:connections error:error];
            }
        }];
        return;
    }

    if ([self.target respondsToSelector:@selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:)]) {
        [self.target captureOutput:output didFinishRecordingToOutputFileAtURL:outputFileURL fromConnections:connections error:error];
    }
}

@end

#pragma mark - Categories for Swizzling

@interface AVCaptureVideoDataOutput (VCamHook)
@end

@implementation AVCaptureVideoDataOutput (VCamHook)
- (void)vcam_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                               queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (!sampleBufferDelegate) {
        objc_setAssociatedObject(self, kVCamVideoProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:nil queue:sampleBufferCallbackQueue];
        return;
    }
    VCamVideoDelegateProxy *proxy = [[VCamVideoDelegateProxy alloc] init];
    proxy.target = sampleBufferDelegate;
    objc_setAssociatedObject(self, kVCamVideoProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self vcam_setSampleBufferDelegate:proxy queue:sampleBufferCallbackQueue];
}
@end

@interface AVCapturePhotoOutput (VCamHook)
@end

@implementation AVCapturePhotoOutput (VCamHook)
- (void)vcam_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                             delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (!delegate) {
        [self vcam_capturePhotoWithSettings:settings delegate:nil];
        return;
    }
    VCamPhotoDelegateProxy *proxy = [[VCamPhotoDelegateProxy alloc] init];
    proxy.target = delegate;
    [self vcam_capturePhotoWithSettings:settings delegate:proxy];
}
@end

@interface AVCapturePhoto (VCamHook)
@end

@implementation AVCapturePhoto (VCamHook)

- (NSData *)vcam_fileDataRepresentation {
    NSData *rep = objc_getAssociatedObject(self, kVCamPhotoDataKey);
    if (rep.length > 0) {
        return rep;
    }
    return [self vcam_fileDataRepresentation];
}

- (NSData *)vcam_fileDataRepresentationWithCustomizer:(id<AVCapturePhotoFileDataRepresentationCustomizer>)customizer {
    NSData *rep = objc_getAssociatedObject(self, kVCamPhotoDataKey);
    if (rep.length > 0) {
        return rep;
    }
    return [self vcam_fileDataRepresentationWithCustomizer:customizer];
}

- (nullable UIImage *)vcam_cachedReplacementUIImage {
    UIImage *cached = objc_getAssociatedObject(self, kVCamPhotoUIImageKey);
    if (cached) return cached;
    NSData *rep = objc_getAssociatedObject(self, kVCamPhotoDataKey);
    if (rep.length > 0) {
        UIImage *img = [UIImage imageWithData:rep];
        if (img) {
            objc_setAssociatedObject(self, kVCamPhotoUIImageKey, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return img;
        }
    }
    return nil;
}

- (CGImageRef)vcam_CGImageRepresentation {
    UIImage *img = [self vcam_cachedReplacementUIImage];
    if (img && img.CGImage) {
        return img.CGImage;
    }
    return [self vcam_CGImageRepresentation];
}

- (CGImageRef)vcam_previewCGImageRepresentation {
    UIImage *img = [self vcam_cachedReplacementUIImage];
    if (img && img.CGImage) {
        return img.CGImage;
    }
    return [self vcam_previewCGImageRepresentation];
}

@end

@interface AVCaptureStillImageOutput (VCamHook)
@end

@implementation AVCaptureStillImageOutput (VCamHook)

+ (NSData *)vcam_jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer {
    if (jpegSampleBuffer) {
        CFTypeRef rep = CMGetAttachment(jpegSampleBuffer, CFSTR("VCamStillJPEG"), NULL);
        if (rep && CFGetTypeID(rep) == CFDataGetTypeID()) {
            NSData *data = (__bridge NSData *)rep;
            if (data.length > 0) {
                return data;
            }
        }
    }
    return [self vcam_jpegStillImageNSDataRepresentation:jpegSampleBuffer];
}

- (void)vcam_captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection
                                         completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler {
    [self vcam_captureStillImageAsynchronouslyFromConnection:connection completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        if (!error && imageDataSampleBuffer) {
            VCamQueueStore *store = [VCamQueueStore sharedStore];
            NSData *jpegData = [store currentPhotoJPEGData];
            if (store.isEnabled && jpegData.length > 0) {
                CMSetAttachment(imageDataSampleBuffer, CFSTR("VCamStillJPEG"), (__bridge CFDataRef)jpegData, kCMAttachmentMode_ShouldPropagate);
                [store advancePhotoCursorWithReason:@"still_captured"];
            }
        }
        if (handler) {
            handler(imageDataSampleBuffer, error);
        }
    }];
}

@end

@interface AVCaptureMovieFileOutput (VCamHook)
@end

@implementation AVCaptureMovieFileOutput (VCamHook)

- (void)vcam_startRecordingToOutputFileURL:(NSURL *)outputFileURL
                          recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    VCamQueueStore *store = [VCamQueueStore sharedStore];
    NSURL *videoURL = [store currentVideoURL];
    if (store.isEnabled && videoURL) {
        store.isRecordingVideo = YES;
        [[VCamMediaRenderer sharedRenderer] beginVideoPlaybackForURL:videoURL];
    }

    VCamMovieDelegateProxy *proxy = [[VCamMovieDelegateProxy alloc] init];
    proxy.target = delegate;
    proxy.startTime = CACurrentMediaTime();
    objc_setAssociatedObject(self, kVCamMovieProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self vcam_startRecordingToOutputFileURL:outputFileURL recordingDelegate:proxy];
}

- (void)vcam_stopRecording {
    [self vcam_stopRecording];
}

@end

@interface AVAssetWriter (VCamHook)
@end

@implementation AVAssetWriter (VCamHook)

- (BOOL)vcam_hasVideoInput {
    for (AVAssetWriterInput *inp in self.inputs) {
        if ([inp.mediaType isEqualToString:AVMediaTypeVideo]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)vcam_startWriting {
    BOOL ok = [self vcam_startWriting];
    if (ok && [self vcam_hasVideoInput]) {
        VCamQueueStore *store = [VCamQueueStore sharedStore];
        NSURL *videoURL = [store currentVideoURL];
        if (store.isEnabled && videoURL) {
            objc_setAssociatedObject(self, kVCamWriterRecordingActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kVCamWriterStartTimeKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            store.isRecordingVideo = YES;
            [[VCamMediaRenderer sharedRenderer] beginVideoPlaybackForURL:videoURL];
        }
    }
    return ok;
}

- (void)vcam_finishWritingWithCompletionHandler:(void (^)(void))handler {
    BOOL wasActive = [objc_getAssociatedObject(self, kVCamWriterRecordingActiveKey) boolValue];
    NSNumber *startNum = objc_getAssociatedObject(self, kVCamWriterStartTimeKey);
    objc_setAssociatedObject(self, kVCamWriterRecordingActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVCamWriterStartTimeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    double elapsed = startNum ? MAX(0.1, CACurrentMediaTime() - startNum.doubleValue) : 1.0;
    CMTime recDuration = CMTimeMakeWithSeconds(elapsed, 600);

    if (wasActive) {
        [VCamQueueStore sharedStore].isRecordingVideo = NO;
        [[VCamMediaRenderer sharedRenderer] endVideoPlayback];
    }

    __weak typeof(self) weakSelf = self;
    [self vcam_finishWritingWithCompletionHandler:^{
        __strong typeof(self) strongSelf = weakSelf;
        VCamQueueStore *store = [VCamQueueStore sharedStore];
        if (wasActive && strongSelf && strongSelf.status == AVAssetWriterStatusCompleted && store.isEnabled) {
            [[VCamMediaRenderer sharedRenderer] replaceRecordedVideoAtURL:strongSelf.outputURL
                                                         recordedDuration:recDuration
                                                                     mode:store.videoReplaceMode
                                                               completion:^(BOOL replaced) {
                if (replaced || [store.videoReplaceMode isEqualToString:@"frames"]) {
                    [store advanceVideoCursorWithReason:@"asset_writer_recorded"];
                }
                if (handler) handler();
            }];
            return;
        }
        if (handler) handler();
    }];
}

- (BOOL)vcam_finishWriting {
    BOOL wasActive = [objc_getAssociatedObject(self, kVCamWriterRecordingActiveKey) boolValue];
    NSNumber *startNum = objc_getAssociatedObject(self, kVCamWriterStartTimeKey);
    objc_setAssociatedObject(self, kVCamWriterRecordingActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVCamWriterStartTimeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (wasActive) {
        [VCamQueueStore sharedStore].isRecordingVideo = NO;
        [[VCamMediaRenderer sharedRenderer] endVideoPlayback];
    }

    BOOL ok = [self vcam_finishWriting];
    VCamQueueStore *store = [VCamQueueStore sharedStore];
    if (ok && wasActive && store.isEnabled) {
        double elapsed = startNum ? MAX(0.1, CACurrentMediaTime() - startNum.doubleValue) : 1.0;
        CMTime recDuration = CMTimeMakeWithSeconds(elapsed, 600);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[VCamMediaRenderer sharedRenderer] replaceRecordedVideoAtURL:self.outputURL
                                                     recordedDuration:recDuration
                                                                 mode:store.videoReplaceMode
                                                           completion:^(BOOL replaced) {
            if (replaced || [store.videoReplaceMode isEqualToString:@"frames"]) {
                [store advanceVideoCursorWithReason:@"asset_writer_sync_recorded"];
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
    }
    return ok;
}

- (void)vcam_cancelWriting {
    BOOL wasActive = [objc_getAssociatedObject(self, kVCamWriterRecordingActiveKey) boolValue];
    objc_setAssociatedObject(self, kVCamWriterRecordingActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kVCamWriterStartTimeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (wasActive) {
        [VCamQueueStore sharedStore].isRecordingVideo = NO;
        [[VCamMediaRenderer sharedRenderer] endVideoPlayback];
    }
    [self vcam_cancelWriting];
}

@end

@interface AVAssetWriterInput (VCamHook)
@end

@implementation AVAssetWriterInput (VCamHook)

- (BOOL)vcam_appendSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer &&
        [self.mediaType isEqualToString:AVMediaTypeVideo] &&
        [VCamQueueStore sharedStore].isRecordingVideo &&
        CMGetAttachment(sampleBuffer, CFSTR("VCamReplacedFrame"), NULL) == NULL) {
        CMSampleBufferRef rep = [[VCamMediaRenderer sharedRenderer] createReplacementSampleBufferFromOriginal:sampleBuffer];
        if (rep) {
            BOOL ok = [self vcam_appendSampleBuffer:rep];
            CFRelease(rep);
            return ok;
        }
    }
    return [self vcam_appendSampleBuffer:sampleBuffer];
}

@end

@interface AVAssetWriterInputPixelBufferAdaptor (VCamHook)
@end

@implementation AVAssetWriterInputPixelBufferAdaptor (VCamHook)

- (BOOL)vcam_appendPixelBuffer:(CVPixelBufferRef)pixelBuffer withPresentationTime:(CMTime)presentationTime {
    if (pixelBuffer && [VCamQueueStore sharedStore].isRecordingVideo) {
        size_t w = CVPixelBufferGetWidth(pixelBuffer);
        size_t h = CVPixelBufferGetHeight(pixelBuffer);
        OSType fmt = CVPixelBufferGetPixelFormatType(pixelBuffer);
        CVPixelBufferRef rep = [[VCamMediaRenderer sharedRenderer] pixelBufferForCurrentModeMatchingWidth:w height:h pixelFormat:fmt];
        if (rep) {
            BOOL ok = [self vcam_appendPixelBuffer:rep withPresentationTime:presentationTime];
            CVPixelBufferRelease(rep);
            return ok;
        }
    }
    return [self vcam_appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
}

@end

#pragma mark - Hook Installer

@implementation VCamAVFoundationHook

+ (void)installHooks {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        vcam_swizzleMethod(
            [AVCaptureVideoDataOutput class],
            @selector(setSampleBufferDelegate:queue:),
            @selector(vcam_setSampleBufferDelegate:queue:),
            NO
        );

        vcam_swizzleMethod(
            [AVCapturePhotoOutput class],
            @selector(capturePhotoWithSettings:delegate:),
            @selector(vcam_capturePhotoWithSettings:delegate:),
            NO
        );

        vcam_swizzleMethod(
            [AVCapturePhoto class],
            @selector(fileDataRepresentation),
            @selector(vcam_fileDataRepresentation),
            NO
        );
        vcam_swizzleMethod(
            [AVCapturePhoto class],
            @selector(fileDataRepresentationWithCustomizer:),
            @selector(vcam_fileDataRepresentationWithCustomizer:),
            NO
        );
        vcam_swizzleMethod(
            [AVCapturePhoto class],
            @selector(CGImageRepresentation),
            @selector(vcam_CGImageRepresentation),
            NO
        );
        vcam_swizzleMethod(
            [AVCapturePhoto class],
            @selector(previewCGImageRepresentation),
            @selector(vcam_previewCGImageRepresentation),
            NO
        );

        vcam_swizzleMethod(
            [AVCaptureStillImageOutput class],
            @selector(jpegStillImageNSDataRepresentation:),
            @selector(vcam_jpegStillImageNSDataRepresentation:),
            YES
        );
        vcam_swizzleMethod(
            [AVCaptureStillImageOutput class],
            @selector(captureStillImageAsynchronouslyFromConnection:completionHandler:),
            @selector(vcam_captureStillImageAsynchronouslyFromConnection:completionHandler:),
            NO
        );

        vcam_swizzleMethod(
            [AVCaptureMovieFileOutput class],
            @selector(startRecordingToOutputFileURL:recordingDelegate:),
            @selector(vcam_startRecordingToOutputFileURL:recordingDelegate:),
            NO
        );
        vcam_swizzleMethod(
            [AVCaptureMovieFileOutput class],
            @selector(stopRecording),
            @selector(vcam_stopRecording),
            NO
        );

        vcam_swizzleMethod(
            [AVAssetWriter class],
            @selector(startWriting),
            @selector(vcam_startWriting),
            NO
        );
        vcam_swizzleMethod(
            [AVAssetWriter class],
            @selector(finishWritingWithCompletionHandler:),
            @selector(vcam_finishWritingWithCompletionHandler:),
            NO
        );
        vcam_swizzleMethod(
            [AVAssetWriter class],
            @selector(finishWriting),
            @selector(vcam_finishWriting),
            NO
        );
        vcam_swizzleMethod(
            [AVAssetWriter class],
            @selector(cancelWriting),
            @selector(vcam_cancelWriting),
            NO
        );
        vcam_swizzleMethod(
            [AVAssetWriterInput class],
            @selector(appendSampleBuffer:),
            @selector(vcam_appendSampleBuffer:),
            NO
        );
        vcam_swizzleMethod(
            [AVAssetWriterInputPixelBufferAdaptor class],
            @selector(appendPixelBuffer:withPresentationTime:),
            @selector(vcam_appendPixelBuffer:withPresentationTime:),
            NO
        );
    });
}

@end
