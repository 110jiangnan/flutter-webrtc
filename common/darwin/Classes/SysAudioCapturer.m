#import "SysAudioCapturer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
// macOS implementation using ScreenCaptureKit
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface SysAudioCapturer () <SCStreamDelegate, SCStreamOutput>

@property (nonatomic, strong) SCStream *audioStream NS_AVAILABLE_MAC(12_0);
@property (nonatomic, strong) SCContentFilter *contentFilter NS_AVAILABLE_MAC(12_0);

#endif

typedef void (^SysAudioDataCallback)(const void *audioData,
                                     int bitsPerSample,
                                     int sampleRate,
                                     size_t numberOfChannels,
                                     size_t numberOfFrames,
                                     void *userData);

@end

@implementation SysAudioCapturer {
    BOOL _isCapturing;
    dispatch_queue_t _audioProcessingQueue;
    SysAudioDataCallback _audioCallback;
    void *_userData;
    
    // Audio format settings
    NSInteger _sampleRate;
    NSInteger _channels;
    NSInteger _bitsPerSample;
}

#pragma mark - Singleton

+ (instancetype)sharedInstance {
    static SysAudioCapturer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SysAudioCapturer alloc] init];
    });
    return instance;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        _sampleRate = 48000;
        _channels = 2;
        _bitsPerSample = 16;
        _isCapturing = NO;
        _audioCallback = NULL;
        _userData = NULL;
        _audioProcessingQueue = dispatch_queue_create("com.webrtc.sysaudio.processing", DISPATCH_QUEUE_SERIAL);
        
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
        NSLog(@"SysAudioCapturer: Initialized for macOS");
#endif
    }
    return self;
}

#pragma mark - Class Methods

+ (BOOL)isSupported {
#if TARGET_OS_IPHONE
    // iOS: ReplayKit does NOT support system audio capture alone
    NSLog(@"SysAudioCapturer: System audio capture is NOT supported on iOS.");
    return NO;
#elif TARGET_OS_MACCATALYST || TARGET_OS_OSX
    // macOS: Check OS version for ScreenCaptureKit support
    if (@available(macOS 13.0, *)) {
        return YES;
    } else {
        NSLog(@"SysAudioCapturer: macOS < 13.0 has limited support. Please upgrade to macOS 13.0+.");
        return NO;
    }
#else
    return NO;
#endif
}

#pragma mark - Public Methods

- (BOOL)startCapture:(NSError **)error {
    if (_isCapturing) {
        if (error) {
            *error = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Already capturing"}];
        }
        return NO;
    }
    
    // Check platform support
    if (![SysAudioCapturer isSupported]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"System audio capture not supported on this platform"}];
        }
        return NO;
    }
    
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
    if (@available(macOS 13.0, *)) {
        return [self startCaptureWithScreenCaptureKit:error];
    }
#endif
    
    return NO;
}

- (void)stopCapture {
    if (!_isCapturing) {
        return;
    }
    
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
    if (@available(macOS 13.0, *)) {
        [self stopCaptureWithScreenCaptureKit];
    }
#endif
    
    _isCapturing = NO;
    NSLog(@"SysAudioCapturer: Stopped capturing");
}

- (void)setAudioDataCallback:(SysAudioDataCallback)callback userData:(void *)userData {
    _audioCallback = callback;
    _userData = userData;
}

#pragma mark - ScreenCaptureKit Implementation (macOS 13.0+)

#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
- (BOOL)startCaptureWithScreenCaptureKit:(NSError **)error {
    if (@available(macOS 13.0, *)) {
        __block BOOL success = NO;
        __block NSError *setupError = nil;
        
        // Create a dispatch group to wait for async operations
        dispatch_group_t setupGroup = dispatch_group_create();
        dispatch_group_enter(setupGroup);
        
        // 获取当前可共享的内容（显示器、窗口、应用） 关键点：即使只录音频，也需要先获取 displays（显示器列表）
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                             onScreenWindowsOnly:NO
                                             completionHandler:^(SCShareableContent *content, NSError *getContentError) {
            if (getContentError) {
                setupError = getContentError;
                NSLog(@"SysAudioCapturer: Failed to get shareable content: %@", getContentError.localizedDescription);
                dispatch_group_leave(setupGroup);
                return;
            }
            NSLog(@"SysAudioCapturer: [DEBUG] Total Displays Found: %lu", (unsigned long)content.displays.count);
            if (content.displays.count == 0) {
              NSLog(@"SysAudioCapturer: No displays available. User may have denied permission in the picker.");
              setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                               code:3
                                           userInfo:@{NSLocalizedDescriptionKey: @"content.displays.count == 0"}];
              return;
            }
            // 遍历并打印每个显示器的信息
//            for (int i = 0; i < content.displays.count; i++) {
//              SCShareableContentDisplay *display = content.displays[i];
//              NSLog(@"SysAudioCapturer: [DEBUG] Display %d - ID: %llu",
//                    i,
//                    (unsigned long long)display.displayID);
//            }
            // 定义要捕获的内容范围 音频录制关键：只需指定一个显示器（displays.firstObject），无需指定窗口或应用
            self.contentFilter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject
                                                  excludingApplications:@[]
                                                  exceptingWindows:@[]];
            
            if (!self.contentFilter) {
                setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                                 code:3
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to create content filter"}];
                dispatch_group_leave(setupGroup);
                return;
            }
            
            // 配置捕获流的行为
            SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
            streamConfig.capturesAudio = YES;
            if (@available(macOS 15.0, *)) {
                streamConfig.captureMicrophone = NO;  // Only system audio, not microphone
            }
            streamConfig.sampleRate = (NSInteger)self->_sampleRate;
            streamConfig.channelCount = (NSInteger)self->_channels;
            
            // 实际执行捕获的流对象
            self.audioStream = [[SCStream alloc] initWithFilter:self.contentFilter
                                                     configuration:streamConfig
                                                     delegate:self];
            
            if (!self.audioStream) {
                setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                                 code:4
                                             userInfo:@{NSLocalizedDescriptionKey: @"Failed to create SCStream"}];
                dispatch_group_leave(setupGroup);
                return;
            }
            
            // 注册音频数据回调（在指定队列中接收 CMSampleBuffer）
            [self.audioStream addStreamOutput:self
                              type:SCStreamOutputTypeAudio
                              sampleHandlerQueue:self->_audioProcessingQueue
                              error:&setupError];
            
            if (setupError) {
                NSLog(@"SysAudioCapturer: Failed to add stream output: %@", setupError.localizedDescription);
                dispatch_group_leave(setupGroup);
                return;
            }
            
            // Start the stream
            [self.audioStream startCaptureWithCompletionHandler:^(NSError *startError) {
                if (startError) {
                    setupError = startError;
                    NSLog(@"SysAudioCapturer: Failed to start capture: %@", startError.localizedDescription);
                } else {
                    self->_isCapturing = YES;
                    NSLog(@"SysAudioCapturer: Started capturing system audio (SampleRate: %ld, Channels: %ld, BitsPerSample: %ld)",
                          (long)self->_sampleRate, (long)self->_channels, (long)self->_bitsPerSample);
                    success = YES;
                }
                dispatch_group_leave(setupGroup);
            }];
        }];
        
        // Wait for setup to complete (with timeout)
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC));
        dispatch_group_wait(setupGroup, timeout);
        
        if (setupError && error) {
            *error = setupError;
        }
        NSLog(@"SysAudioCapturer: end %hhd", success);
        return success;
    }
    return NO;
}

- (void)stopCaptureWithScreenCaptureKit {
    if (@available(macOS 13.0, *)) {
        if (self.audioStream) {
            [self.audioStream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
                if (error) {
                    NSLog(@"SysAudioCapturer: Error stopping capture: %@", error.localizedDescription);
                } else {
                    NSLog(@"SysAudioCapturer: Capture stopped successfully");
                }
            }];
            self.audioStream = nil;
        }
        
        if (self.contentFilter) {
            self.contentFilter = nil;
        }
    }
}

#pragma mark - SCStreamDelegate Methods

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"SysAudioCapturer: Stream stopped with error: %@", error.localizedDescription);
    _isCapturing = NO;
}

#pragma mark - SCStreamOutput Methods

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofOutputType:(SCStreamOutputType)outputType {
    NSLog(@"SysAudioCapturer: didOutputSampleBuffer");
    if (@available(macOS 13.0, *)) {
        if (outputType != SCStreamOutputTypeAudio) {
            return;
        }
    }
    if (!_audioCallback) {
        return;
    }
    // Process audio sample buffer
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        return;
    }
    size_t totalLength = 0;
    char *dataPointer = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
    if (status != kCMBlockBufferNoErr || !dataPointer) {
        return;
    }
    // Calculate number of frames
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd) {
        return;
    }
    size_t bytesPerFrame = asbd->mBytesPerFrame;
    size_t numberOfFrames = totalLength / bytesPerFrame;
    
    // Call the callback with audio data
    _audioCallback(dataPointer,
                   (int)asbd->mBitsPerChannel,
                   (int)asbd->mSampleRate,
                   asbd->mChannelsPerFrame,
                   numberOfFrames,
                   _userData);
}
#endif

#pragma mark - Dealloc

- (void)dealloc {
    [self stopCapture];
}

@end
