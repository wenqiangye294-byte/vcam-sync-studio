#import "VCamMediaRenderer.h"
#import "VCamQueueStore.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

static CGImagePropertyOrientation VCamOrientationFromPreferredTransform(CGAffineTransform t) {
    if (t.a == 0 && t.b == 1.0 && t.c == -1.0 && t.d == 0) {
        return kCGImagePropertyOrientationRight;
    }
    if (t.a == 0 && t.b == -1.0 && t.c == 1.0 && t.d == 0) {
        return kCGImagePropertyOrientationLeft;
    }
    if (t.a == -1.0 && t.b == 0 && t.c == 0 && t.d == -1.0) {
        return kCGImagePropertyOrientationDown;
    }
    return kCGImagePropertyOrientationUp;
}

@interface VCamMediaRenderer ()
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) CIContext *ciContext;

@property (nonatomic, assign) CVPixelBufferPoolRef pixelPool;
@property (nonatomic, assign) size_t poolWidth;
@property (nonatomic, assign) size_t poolHeight;
@property (nonatomic, assign) OSType poolFormat;

@property (nonatomic, assign) CVPixelBufferRef cachedPhotoBuffer;
@property (nonatomic, copy) NSString *cachedPhotoKey;

@property (nonatomic, strong) NSURL *activeVideoURL;
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, assign) CGImagePropertyOrientation videoOrientation;
@property (nonatomic, assign) CFTimeInterval videoStartTime;
@property (nonatomic, assign) double videoDurationSec;
@property (nonatomic, assign) double lastDecodedPTS;
@property (nonatomic, strong) CIImage *lastVideoImage;
@end

@implementation VCamMediaRenderer

+ (instancetype)sharedRenderer {
    static VCamMediaRenderer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamMediaRenderer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO
        }];
        _videoOrientation = kCGImagePropertyOrientationUp;
    }
    return self;
}

- (void)dealloc {
    if (_pixelPool) {
        CVPixelBufferPoolRelease(_pixelPool);
        _pixelPool = NULL;
    }
    if (_cachedPhotoBuffer) {
        CVPixelBufferRelease(_cachedPhotoBuffer);
        _cachedPhotoBuffer = NULL;
    }
}

- (CVPixelBufferRef)createBufferFromPoolWithWidth:(size_t)width height:(size_t)height pixelFormat:(OSType)fmt CF_RETURNS_RETAINED {
    if (!_pixelPool || _poolWidth != width || _poolHeight != height || _poolFormat != fmt) {
        if (_pixelPool) {
            CVPixelBufferPoolRelease(_pixelPool);
            _pixelPool = NULL;
        }
        NSDictionary *pbAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)pbAttrs, &_pixelPool);
        _poolWidth = width;
        _poolHeight = height;
        _poolFormat = fmt;
    }

    CVPixelBufferRef buf = NULL;
    if (_pixelPool) {
        CVReturn rc = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pixelPool, &buf);
        if (rc == kCVReturnSuccess && buf) {
            return buf;
        }
    }
    NSDictionary *fallbackAttrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt, (__bridge CFDictionaryRef)fallbackAttrs, &buf);
    return buf;
}

- (CIImage *)composeCIImage:(CIImage *)source
                targetWidth:(size_t)targetW
               targetHeight:(size_t)targetH
                   fillMode:(NSString *)fillMode
                   rotation:(NSInteger)rotation
                     mirror:(BOOL)mirror {
    if (!source || targetW == 0 || targetH == 0) {
        return nil;
    }
    CIImage *img = source;
    CGRect ext = img.extent;
    if (CGRectIsEmpty(ext) || CGRectIsInfinite(ext)) {
        return nil;
    }
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];

    if (mirror) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(-1.0, 1.0)];
        CGRect me = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-me.origin.x, -me.origin.y)];
    }

    NSInteger normRot = ((rotation % 360) + 360) % 360;
    if (normRot != 0) {
        // CoreImage Y-axis points up, so clockwise visual rotation uses negative radians
        CGFloat rad = -(CGFloat)normRot * (CGFloat)M_PI / 180.0;
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(rad)];
        CGRect re = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(-re.origin.x, -re.origin.y)];
    }

    CGRect curExt = img.extent;
    if (curExt.size.width <= 0 || curExt.size.height <= 0) {
        return nil;
    }

    CGFloat sx = (CGFloat)targetW / curExt.size.width;
    CGFloat sy = (CGFloat)targetH / curExt.size.height;
    CGFloat scale = [fillMode isEqualToString:@"fit"] ? MIN(sx, sy) : MAX(sx, sy);

    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExt = img.extent;
    CGFloat dx = ((CGFloat)targetW - scaledExt.size.width) * 0.5 - scaledExt.origin.x;
    CGFloat dy = ((CGFloat)targetH - scaledExt.size.height) * 0.5 - scaledExt.origin.y;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];

    CGRect canvasRect = CGRectMake(0, 0, (CGFloat)targetW, (CGFloat)targetH);
    CIImage *bg = [[CIImage imageWithColor:[CIColor blackColor]] imageByCroppingToRect:canvasRect];
    CIImage *composed = [img imageByCompositingOverImage:bg];
    return [composed imageByCroppingToRect:canvasRect];
}

- (void)openAssetReaderLockedForURL:(NSURL *)videoURL {
    if (_assetReader) {
        [_assetReader cancelReading];
        _assetReader = nil;
        _trackOutput = nil;
    }
    if (!videoURL) {
        return;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    AVAssetTrack *videoTrack = tracks.firstObject;
    if (!videoTrack) {
        return;
    }

    _videoOrientation = VCamOrientationFromPreferredTransform(videoTrack.preferredTransform);
    _videoDurationSec = CMTimeGetSeconds(asset.duration);
    if (isnan(_videoDurationSec) || _videoDurationSec <= 0.05) {
        _videoDurationSec = 3.0;
    }

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader || err) {
        return;
    }
    NSDictionary *outSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:outSettings];
    output.alwaysCopiesSampleData = NO;
    if ([reader canAddOutput:output]) {
        [reader addOutput:output];
        if ([reader startReading]) {
            _assetReader = reader;
            _trackOutput = output;
            _videoStartTime = CACurrentMediaTime();
            _lastDecodedPTS = -1.0;
        }
    }
}

- (void)beginVideoPlaybackForURL:(NSURL *)videoURL {
    [self.lock lock];
    self.activeVideoURL = videoURL;
    self.lastVideoImage = nil;
    [self openAssetReaderLockedForURL:videoURL];
    [self.lock unlock];
}

- (void)endVideoPlayback {
    [self.lock lock];
    if (self.assetReader) {
        [self.assetReader cancelReading];
    }
    self.assetReader = nil;
    self.trackOutput = nil;
    self.activeVideoURL = nil;
    self.lastVideoImage = nil;
    [self.lock unlock];
}

- (CIImage *)currentVideoCIImageLocked {
    if (!self.activeVideoURL) {
        return nil;
    }
    if (!self.assetReader || self.assetReader.status == AVAssetReaderStatusCompleted || self.assetReader.status == AVAssetReaderStatusFailed) {
        [self openAssetReaderLockedForURL:self.activeVideoURL];
    }
    if (!self.trackOutput) {
        return self.lastVideoImage;
    }

    CFTimeInterval now = CACurrentMediaTime();
    double elapsed = now - self.videoStartTime;
    if (elapsed > self.videoDurationSec && self.videoDurationSec > 0.1) {
        [self openAssetReaderLockedForURL:self.activeVideoURL];
        elapsed = 0.0;
    }

    while (self.assetReader.status == AVAssetReaderStatusReading) {
        if (self.lastVideoImage && self.lastDecodedPTS >= elapsed) {
            break;
        }
        CMSampleBufferRef sb = [self.trackOutput copyNextSampleBuffer];
        if (!sb) {
            break;
        }
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        double ptsSec = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : (self.lastDecodedPTS + 0.033);
        CVImageBufferRef imgBuf = CMSampleBufferGetImageBuffer(sb);
        if (imgBuf) {
            CIImage *frameImg = [CIImage imageWithCVPixelBuffer:imgBuf];
            if (self.videoOrientation != kCGImagePropertyOrientationUp) {
                frameImg = [frameImg imageByApplyingOrientation:self.videoOrientation];
            }
            self.lastVideoImage = frameImg;
            self.lastDecodedPTS = ptsSec;
        }
        CFRelease(sb);
        if (self.lastDecodedPTS >= elapsed) {
            break;
        }
    }

    return self.lastVideoImage;
}

- (nullable CVPixelBufferRef)pixelBufferForStore:(VCamQueueStore *)store
                                           width:(size_t)width
                                          height:(size_t)height
                                     pixelFormat:(OSType)pixelFormat CF_RETURNS_RETAINED {
    if (store.isRecordingVideo) {
        NSURL *videoURL = [store currentVideoURL];
        if (videoURL) {
            [self.lock lock];
            if (!self.activeVideoURL || ![self.activeVideoURL isEqual:videoURL]) {
                self.activeVideoURL = videoURL;
                self.lastVideoImage = nil;
                [self openAssetReaderLockedForURL:videoURL];
            }
            CIImage *videoImg = [self currentVideoCIImageLocked];
            CIImage *composed = [self composeCIImage:videoImg
                                         targetWidth:width
                                        targetHeight:height
                                            fillMode:store.fillMode
                                            rotation:store.rotation
                                              mirror:store.mirror];
            CVPixelBufferRef buf = NULL;
            if (composed) {
                buf = [self createBufferFromPoolWithWidth:width height:height pixelFormat:pixelFormat];
                if (buf) {
                    [self.ciContext render:composed toCVPixelBuffer:buf];
                }
            }
            [self.lock unlock];
            if (buf) {
                return buf;
            }
        }
    }

    NSURL *photoURL = [store currentPhotoURL];
    if (!photoURL) {
        // Fallback: if user only uploaded video, preview its first frame
        NSURL *fallbackVideo = [store currentVideoURL];
        if (!fallbackVideo) {
            return NULL;
        }
        [self.lock lock];
        if (!self.activeVideoURL || ![self.activeVideoURL isEqual:fallbackVideo]) {
            self.activeVideoURL = fallbackVideo;
            self.lastVideoImage = nil;
            [self openAssetReaderLockedForURL:fallbackVideo];
        }
        CIImage *videoImg = [self currentVideoCIImageLocked];
        CIImage *composed = [self composeCIImage:videoImg
                                     targetWidth:width
                                    targetHeight:height
                                        fillMode:store.fillMode
                                        rotation:store.rotation
                                          mirror:store.mirror];
        CVPixelBufferRef buf = NULL;
        if (composed) {
            buf = [self createBufferFromPoolWithWidth:width height:height pixelFormat:pixelFormat];
            if (buf) {
                [self.ciContext render:composed toCVPixelBuffer:buf];
            }
        }
        [self.lock unlock];
        return buf;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@|%ld|%ld|%zu|%zu|%u|%@|%ld|%d",
                          photoURL.path,
                          (long)store.revision,
                          (long)store.photoCursor,
                          width,
                          height,
                          (unsigned int)pixelFormat,
                          store.fillMode,
                          (long)store.rotation,
                          store.mirror ? 1 : 0];

    [self.lock lock];
    if (self.cachedPhotoBuffer && [self.cachedPhotoKey isEqualToString:cacheKey]) {
        CVPixelBufferRef retained = CVPixelBufferRetain(self.cachedPhotoBuffer);
        [self.lock unlock];
        return retained;
    }
    [self.lock unlock];

    NSData *jpegData = [store currentPhotoJPEGData];
    CIImage *src = jpegData ? [CIImage imageWithData:jpegData] : [CIImage imageWithContentsOfURL:photoURL];
    if (!src) {
        return NULL;
    }

    [self.lock lock];
    CIImage *composed = [self composeCIImage:src
                                 targetWidth:width
                                targetHeight:height
                                    fillMode:store.fillMode
                                    rotation:store.rotation
                                      mirror:store.mirror];
    CVPixelBufferRef newBuf = NULL;
    if (composed) {
        newBuf = [self createBufferFromPoolWithWidth:width height:height pixelFormat:pixelFormat];
        if (newBuf) {
            [self.ciContext render:composed toCVPixelBuffer:newBuf];
            if (self.cachedPhotoBuffer) {
                CVPixelBufferRelease(self.cachedPhotoBuffer);
            }
            self.cachedPhotoBuffer = CVPixelBufferRetain(newBuf);
            self.cachedPhotoKey = cacheKey;
        }
    }
    [self.lock unlock];
    return newBuf;
}

- (nullable CVPixelBufferRef)pixelBufferForCurrentModeMatchingWidth:(size_t)width
                                                           height:(size_t)height
                                                      pixelFormat:(OSType)pixelFormat CF_RETURNS_RETAINED {
    VCamQueueStore *store = [VCamQueueStore sharedStore];
    if (![store shouldReplaceVideoStream]) {
        return NULL;
    }
    return [self pixelBufferForStore:store width:width height:height pixelFormat:pixelFormat];
}

- (nullable CMSampleBufferRef)createReplacementSampleBufferFromOriginal:(CMSampleBufferRef)originalSampleBuffer CF_RETURNS_RETAINED {
    if (!originalSampleBuffer) {
        return NULL;
    }
    VCamQueueStore *store = [VCamQueueStore sharedStore];
    if (![store shouldReplaceVideoStream]) {
        return NULL;
    }

    CVImageBufferRef origImg = CMSampleBufferGetImageBuffer(originalSampleBuffer);
    if (!origImg) {
        return NULL;
    }
    size_t width = CVPixelBufferGetWidth(origImg);
    size_t height = CVPixelBufferGetHeight(origImg);
    OSType fmt = CVPixelBufferGetPixelFormatType(origImg);
    if (width == 0 || height == 0) {
        return NULL;
    }

    CVPixelBufferRef repBuf = [self pixelBufferForStore:store width:width height:height pixelFormat:fmt];
    if (!repBuf) {
        return NULL;
    }

    CMSampleTimingInfo timingInfo = kCMTimingInfoInvalid;
    OSStatus timingErr = CMSampleBufferGetSampleTimingInfo(originalSampleBuffer, 0, &timingInfo);
    if (timingErr != noErr) {
        timingInfo.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originalSampleBuffer);
        timingInfo.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originalSampleBuffer);
        timingInfo.duration = CMSampleBufferGetDuration(originalSampleBuffer);
    }

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    OSStatus descErr = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, repBuf, &fmtDesc);
    if (descErr != noErr || !fmtDesc) {
        CVPixelBufferRelease(repBuf);
        return NULL;
    }

    CMSampleBufferRef outSB = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        repBuf,
        fmtDesc,
        &timingInfo,
        &outSB
    );
    if (outSB) {
        CMSetAttachment(outSB, CFSTR("VCamReplacedFrame"), kCFBooleanTrue, kCMAttachmentMode_ShouldNotPropagate);
    }
    CFRelease(fmtDesc);
    CVPixelBufferRelease(repBuf);
    return outSB;
}

- (void)replaceRecordedVideoAtURL:(NSURL *)destURL
                 recordedDuration:(CMTime)duration
                             mode:(NSString *)mode
                       completion:(void (^)(BOOL replaced))completion {
    if (!destURL) {
        if (completion) completion(NO);
        return;
    }
    if ([mode isEqualToString:@"frames"]) {
        if (completion) completion(NO);
        return;
    }
    NSURL *srcURL = [[VCamQueueStore sharedStore] currentVideoURL];
    if (!srcURL || ![[NSFileManager defaultManager] fileExistsAtPath:srcURL.path]) {
        if (completion) completion(NO);
        return;
    }

    if ([mode isEqualToString:@"trim"] && CMTIME_IS_VALID(duration) && CMTimeGetSeconds(duration) > 0.25) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:srcURL options:nil];
        CMTime assetDur = asset.duration;
        if (CMTIME_IS_VALID(assetDur) && CMTimeCompare(duration, assetDur) < 0) {
            NSURL *tmpURL = [destURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@"vcam_trim_%@.mp4", NSUUID.UUID.UUIDString]];
            AVAssetExportSession *exporter = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
            if (exporter) {
                NSString *ext = destURL.pathExtension.lowercaseString;
                AVFileType targetType = [ext isEqualToString:@"mov"] ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4;
                if ([exporter.supportedFileTypes containsObject:targetType]) {
                    exporter.outputFileType = targetType;
                } else {
                    exporter.outputFileType = exporter.supportedFileTypes.firstObject ?: AVFileTypeMPEG4;
                }
                exporter.outputURL = tmpURL;
                exporter.timeRange = CMTimeRangeMake(kCMTimeZero, duration);
                [exporter exportAsynchronouslyWithCompletionHandler:^{
                    BOOL ok = NO;
                    if (exporter.status == AVAssetExportSessionStatusCompleted) {
                        NSFileManager *fm = [NSFileManager defaultManager];
                        [fm removeItemAtURL:destURL error:nil];
                        ok = [fm moveItemAtURL:tmpURL toURL:destURL error:nil];
                    } else {
                        [[NSFileManager defaultManager] removeItemAtURL:tmpURL error:nil];
                        NSFileManager *fm = [NSFileManager defaultManager];
                        [fm removeItemAtURL:destURL error:nil];
                        ok = [fm copyItemAtURL:srcURL toURL:destURL error:nil];
                    }
                    if (completion) completion(ok);
                }];
                return;
            }
        }
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *tmpCopy = [destURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@"vcam_full_%@.%@", NSUUID.UUID.UUIDString, destURL.pathExtension.length ? destURL.pathExtension : @"mp4"]];
    [fm removeItemAtURL:tmpCopy error:nil];
    BOOL copied = [fm copyItemAtURL:srcURL toURL:tmpCopy error:nil];
    BOOL ok = NO;
    if (copied) {
        [fm removeItemAtURL:destURL error:nil];
        ok = [fm moveItemAtURL:tmpCopy toURL:destURL error:nil];
    }
    if (!ok) {
        [fm removeItemAtURL:tmpCopy error:nil];
        [fm removeItemAtURL:destURL error:nil];
        ok = [fm copyItemAtURL:srcURL toURL:destURL error:nil];
    }
    if (completion) completion(ok);
}

@end
