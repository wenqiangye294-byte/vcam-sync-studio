#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamMediaRenderer : NSObject

+ (instancetype)sharedRenderer;

- (void)beginVideoPlaybackForURL:(NSURL *)videoURL;
- (void)endVideoPlayback;

- (nullable CVPixelBufferRef)pixelBufferForCurrentModeMatchingWidth:(size_t)width
                                                           height:(size_t)height
                                                      pixelFormat:(OSType)pixelFormat CF_RETURNS_RETAINED;

- (nullable CMSampleBufferRef)createReplacementSampleBufferFromOriginal:(CMSampleBufferRef)originalSampleBuffer CF_RETURNS_RETAINED;

- (void)replaceRecordedVideoAtURL:(NSURL *)destURL
                 recordedDuration:(CMTime)duration
                             mode:(NSString *)mode
                       completion:(void (^)(BOOL replaced))completion;

@end

NS_ASSUME_NONNULL_END
