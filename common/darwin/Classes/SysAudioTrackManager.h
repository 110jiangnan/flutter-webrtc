#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import "SysAudioCapturer.h"

@class FlutterWebRTCPlugin;

NS_ASSUME_NONNULL_BEGIN

@interface SysAudioTrackManager : NSObject

@property (nonatomic, strong) SysAudioCapturer *audioCapturer;
@property (nonatomic, strong) RTCAudioSource *audioSource;
@property (nonatomic, assign) BOOL isInitialized;
@property (nonatomic, strong) NSString *currentDeviceId;
@property (nonatomic, assign) BOOL enablePcmRecording;
@property (nonatomic, strong) NSString *pcmFilePath;

/**
 * YES if currently capturing
 */
@property (nonatomic, assign, readonly) BOOL isCapturing;

/**
 * Shared instance
 */
+ (instancetype)sharedInstance;

/**
 * Initialize system audio capture
 * @param plugin FlutterWebRTCPlugin instance for accessing factory
 * @param deviceId Device ID to use (empty for default)
 * @param error Error pointer if initialization fails
 * @return YES if successfully initialized
 */
- (BOOL)initWithPlugin:(FlutterWebRTCPlugin *)plugin
              deviceId:(nullable NSString *)deviceId
                 error:(NSError **)error;

/**
 * Start capturing (if initialized but stopped)
 */
- (BOOL)startCapture;

/**
 * Stop capturing
 */
- (void)stopCapture;

/**
 * Create WebRTC audio track from captured audio
 * @param trackId Track identifier (auto-generated if empty)
 * @return RTCAudioTrack or nil if failed
 */
- (nullable RTCAudioTrack *)createSystemAudioTrack:(FlutterWebRTCPlugin *)plugin (nullable NSString *)trackId;

/**
 * Create WebRTC media stream with system audio
 * @param plugin FlutterWebRTCPlugin instance
 * @param streamId Stream identifier (auto-generated if empty)
 * @param resultData Dictionary to populate with stream info
 * @return RTCMediaStream or nil if failed
 */
- (nullable RTCMediaStream *)createSystemAudioMediaStream:(FlutterWebRTCPlugin *)plugin
                                                 streamId:(nullable NSString *)streamId
                                             resultData:(NSMutableDictionary *)resultData;

/**
 * Get system audio media stream with full initialization flow
 * @param plugin FlutterWebRTCPlugin instance
 * @param deviceId Device ID to use (empty for default)
 * @param streamId Stream identifier (auto-generated if empty)
 * @param enablePcmRecording Enable PCM file recording
 * @param pcmFilePath Path for PCM file (empty for auto-generated)
 * @param error Error pointer if operation fails
 * @return Dictionary with stream info or nil if failed
 */

- (nullable NSMutableDictionary *)getSysAudioMediaWithPlugin:(FlutterWebRTCPlugin *)plugin
                                                    deviceId:(nullable NSString *)deviceId
                                                    streamId:(nullable NSString *)streamId
                                          enablePcmRecording:(BOOL)enablePcmRecording
                                                 pcmFilePath:(nullable NSString *)pcmFilePath
                                                       error:(NSError **)error;

/**
 * Release system audio media stream and cleanup resources
 * @param plugin FlutterWebRTCPlugin instance
 * @param streamId Stream identifier to release
 */

- (void)releaseSysAudioMediaWithPlugin:(FlutterWebRTCPlugin *)plugin
                              streamId:(nullable NSString *)streamId;

/**
 * Dispose all resources
 */
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
