//
//  GStreamerPreviewEngine.h
//  StudyCast
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^GStreamerPreviewFrameHandler)(CGImageRef image);
typedef void (^GStreamerPreviewErrorHandler)(NSString *message);

@interface GStreamerPreviewEngine : NSObject

+ (void)configureRuntimeEnvironment;

- (BOOL)startWithVideoPort:(NSInteger)videoPort
                 audioPort:(NSInteger)audioPort
       audioOutputDeviceID:(NSInteger)audioOutputDeviceID
                   onFrame:(GStreamerPreviewFrameHandler)onFrame
                   onError:(GStreamerPreviewErrorHandler)onError;
- (BOOL)restartAudioWithOutputDeviceID:(NSInteger)audioOutputDeviceID;
- (void)stop;
- (void)setMuted:(BOOL)muted;
- (void)setVolume:(double)volume;

@end

NS_ASSUME_NONNULL_END
