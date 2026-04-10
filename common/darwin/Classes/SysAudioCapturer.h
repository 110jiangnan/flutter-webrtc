#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>

#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

// Audio data callback type
typedef void (^SysAudioDataCallback)(const void *audioData,
                                     int bitsPerSample,
                                     int sampleRate,
                                     int numberOfChannels,
                                     int numberOfFrames,
                                     void *userData);
typedef void(^StartCaptureCompletion)(BOOL success, NSError *error);

API_AVAILABLE(macos(14.0))
@interface SysAudioCapturer : NSObject<SCStreamDelegate, SCStreamOutput>

@property (nonatomic, assign, readonly) BOOL isCapturing;

@property (nonatomic, assign) NSInteger sampleRate;

@property (nonatomic, assign) NSInteger channels;

@property (nonatomic, assign) NSInteger bitsPerSample;

/**
 * Shared instance for system audio capture
 */
+ (instancetype)sharedInstance;

/**
 * Check if system audio capture is supported on this device
 */
+ (BOOL)isSupported;

- (void)startCapture:(NSError **)error completion:(StartCaptureCompletion)completionBlock;

/**
 * Stop capturing system audio
 */
- (void)stopCapture;

- (void)setAudioDataCallback:(SysAudioDataCallback)callback userData:(void *)userData;

@end

NS_ASSUME_NONNULL_END
