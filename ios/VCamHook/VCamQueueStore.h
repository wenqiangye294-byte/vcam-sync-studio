#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const VCamQueueStoreDidChangeNotification;

@interface VCamQueueStore : NSObject

+ (instancetype)sharedStore;

@property (nonatomic, readonly, copy) NSString *activeBaseDirectory;
@property (nonatomic, readonly) BOOL isEnabled;
@property (nonatomic, readonly) BOOL showHUD;
@property (nonatomic, readonly) BOOL loopPhotos;
@property (nonatomic, readonly) BOOL loopVideos;
@property (nonatomic, readonly, copy) NSString *fillMode;
@property (nonatomic, readonly) NSInteger rotation;
@property (nonatomic, readonly) BOOL mirror;
@property (nonatomic, readonly, copy) NSString *videoReplaceMode;
@property (nonatomic, readonly) NSInteger revision;
@property (nonatomic, readonly, copy) NSString *productID;
@property (nonatomic, readonly, copy) NSString *productName;
@property (nonatomic, readonly) NSInteger photoCursor;
@property (nonatomic, readonly) NSInteger photoCount;
@property (nonatomic, readonly) NSInteger videoCursor;
@property (nonatomic, readonly) NSInteger videoCount;

@property (atomic, assign) BOOL isRecordingVideo;

- (void)reloadIfNeeded;
- (void)forceReload;

- (BOOL)shouldReplaceVideoStream;
- (nullable NSURL *)currentPhotoURL;
- (nullable NSData *)currentPhotoJPEGData;
- (nullable NSURL *)currentVideoURL;

- (void)advancePhotoCursorWithReason:(NSString *)reason;
- (void)advanceVideoCursorWithReason:(NSString *)reason;
- (void)stepPhotoCursorBy:(NSInteger)delta;
- (void)stepVideoCursorBy:(NSInteger)delta;
- (void)toggleEnabled;

@end

NS_ASSUME_NONNULL_END
