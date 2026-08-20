#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import "SysAudioCapturer.h"
#import <math.h>

@class WebrtcPlugin;

NS_ASSUME_NONNULL_BEGIN

@interface SysAudioTrackManager : NSObject

@property (nonatomic, strong, nullable) SysAudioCapturer *audioCapturer;
@property (nonatomic, strong, nullable) RTCAudioSource *audioSource;
@property (nonatomic, assign) BOOL isInitialized;
@property (nonatomic, strong) NSString *currentDeviceId;
@property (nonatomic, assign) BOOL enablePcmRecording;
@property (nonatomic, strong) NSString *pcmFilePath;
@property (nonatomic, assign) BOOL isCapturing;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, RTCAudioTrack *> *audioTracks;

+ (instancetype)sharedInstance;

- (BOOL)initWithPlugin:(WebrtcPlugin *)plugin
              deviceId:(nullable NSString *)deviceId
                 error:(NSError **)error;

- (BOOL)startCapture;

- (void)stopCapture;

- (nullable RTCAudioTrack *)createSystemAudioTrack:(WebrtcPlugin *)plugin trackId:(nullable NSString *)trackId;

- (nullable RTCMediaStream *)createSystemAudioMediaStream:(WebrtcPlugin *)plugin
                                                 streamId:(nullable NSString *)streamId
                                             resultData:(NSMutableDictionary *)resultData;

- (nullable NSMutableDictionary *)getSysAudioMediaWithPlugin:(WebrtcPlugin *)plugin
                                                    deviceId:(nullable NSString *)deviceId
                                                    streamId:(nullable NSString *)streamId
                                          enablePcmRecording:(BOOL)enablePcmRecording
                                                 pcmFilePath:(nullable NSString *)pcmFilePath
                                                       error:(NSError **)error;

- (void)releaseSysAudioMediaWithPlugin:(WebrtcPlugin *)plugin
                              streamId:(nullable NSString *)streamId;

- (void)dispose;

- (NSData *)testGeneratePcmData;

@end

NS_ASSUME_NONNULL_END
