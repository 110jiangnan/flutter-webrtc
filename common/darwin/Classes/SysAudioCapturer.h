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
                                     size_t numberOfChannels,
                                     size_t numberOfFrames,
                                     void *userData);

API_AVAILABLE(macos(10.15))
@interface SysAudioCapturer : NSObject

/**
 * YES if currently capturing audio
 */
@property (nonatomic, assign, readonly) BOOL isCapturing;

/**
 * Sample rate (default: 48000 Hz)
 */
@property (nonatomic, assign) NSInteger sampleRate;

/**
 * Number of channels (default: 2 for stereo)
 */
@property (nonatomic, assign) NSInteger channels;

/**
 * Bits per sample (default: 16)
 */
@property (nonatomic, assign) NSInteger bitsPerSample;

/**
 * Shared instance for system audio capture
 */
+ (instancetype)sharedInstance;

/**
 * Check if system audio capture is supported on this device
 */
+ (BOOL)isSupported;

/**
 * Start capturing system audio
 * macOS 13.0+: Requires ScreenCaptureKit permission
 * @param error Error pointer if start fails
 * @return YES if successfully started
 */
- (BOOL)startCapture:(NSError **)error;

/**
 * Stop capturing system audio
 */
- (void)stopCapture;

/**
 * Set callback to receive audio data
 * @param callback Block called when audio data is available
 * @param userData User data passed to callback
 */
- (void)setAudioDataCallback:(SysAudioDataCallback)callback userData:(void *)userData;

@end

NS_ASSUME_NONNULL_END
