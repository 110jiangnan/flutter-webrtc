#import "SysAudioCapturer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
// macOS implementation using ScreenCaptureKit
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface SysAudioCapturer () <SCStreamDelegate, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic, strong) SCStream *audioStream API_AVAILABLE(macos(12.3));
@property (nonatomic, strong) SCContentFilter *contentFilter API_AVAILABLE(macos(12.3));
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureDevice *audioDevice;
@property (nonatomic, strong) AVCaptureDeviceInput *audioInput;
@property (nonatomic, strong) AVCaptureAudioDataOutput *audioOutput;

#endif

typedef void (^SysAudioDataCallback)(const void *audioData,
                                     int bitsPerSample,
                                     int sampleRate,
                                     int numberOfChannels,
                                     int numberOfFrames,
                                     void *userData);

typedef void(^StartCaptureCompletion)(BOOL success, NSError *error);

@end

@implementation SysAudioCapturer {
    BOOL _isCapturing;
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
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
        NSLog(@"SysAudioCapturer: Initialized for macOS");
#endif
    }
    return self;
}

#pragma mark - Class Methods

+ (BOOL)isSupported {
#if TARGET_OS_IPHONE
    NSLog(@"SysAudioCapturer: System audio capture is NOT supported on iOS.");
    return NO;
#elif TARGET_OS_MACCATALYST || TARGET_OS_OSX
    return YES;
#else
    return NO;
#endif
}

#pragma mark - Public Methods

- (void)startCapture:(NSError **)error completion:(StartCaptureCompletion)completionBlock {
    if (_isCapturing) {
        if (error) {
            *error = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Already capturing"}];
        }
        if (completionBlock) {
            completionBlock(NO, *error);
        }
        return;
    }
    
    // Check platform support
    if (![SysAudioCapturer isSupported]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"System audio capture not supported on this platform"}];
        }
        if (completionBlock) {
            completionBlock(NO, *error);
        }
        return;
    }
    
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
    if (@available(macOS 13.0, *)) {
        // Try AVCaptureSession first
        // if ([self startCaptureWithScreenCaptureKit:error completion:completionBlock]) {
        //     return;
        // }
        // Fallback to ScreenCaptureKit if AVCaptureSession fails
        [self startCaptureWithScreenCaptureKit:error completion:completionBlock];
    } else {
        if (error) {
            *error = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"macOS version not supported"}];
        }
        if (completionBlock) {
            completionBlock(NO, *error);
        }
    }
#else
    if (error) {
        *error = [NSError errorWithDomain:@"SysAudioCapturer"
                                     code:4
                                 userInfo:@{NSLocalizedDescriptionKey: @"Platform not supported"}];
    }
    if (completionBlock) {
        completionBlock(NO, *error);
    }
#endif
}

- (void)stopCapture {
    if (!_isCapturing) {
        return;
    }
    
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
    if (self.captureSession) {
        [self.captureSession stopRunning];
        self.captureSession = nil;
    }
    
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

#pragma mark - AVCaptureSession Implementation

#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
- (BOOL)startCaptureWithAVCaptureSession:(NSError **)error completion:(StartCaptureCompletion)completionBlock {
    NSError *setupError = nil;
    
    // Create capture session
    self.captureSession = [[AVCaptureSession alloc] init];
    
    // Get default audio input device
    self.audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (!self.audioDevice) {
        setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"No audio device found"}];
        if (error) *error = setupError;
        if (completionBlock) completionBlock(NO, setupError);
        return NO;
    }
    
    // Create audio input
    self.audioInput = [AVCaptureDeviceInput deviceInputWithDevice:self.audioDevice error:&setupError];
    if (!self.audioInput) {
        if (error) *error = setupError;
        if (completionBlock) completionBlock(NO, setupError);
        return NO;
    }
    
    // Add audio input to session
    if ([self.captureSession canAddInput:self.audioInput]) {
        [self.captureSession addInput:self.audioInput];
    } else {
        setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot add audio input to session"}];
        if (error) *error = setupError;
        if (completionBlock) completionBlock(NO, setupError);
        return NO;
    }
    
    // Create audio output
    self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    
    // Set audio data delegate
    dispatch_queue_t audioQueue = dispatch_queue_create("com.sysaudio.capturer.audio", DISPATCH_QUEUE_SERIAL);
    [self.audioOutput setSampleBufferDelegate:self queue:audioQueue];
    
    // Add audio output to session
    if ([self.captureSession canAddOutput:self.audioOutput]) {
        [self.captureSession addOutput:self.audioOutput];
    } else {
        setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                         code:7
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot add audio output to session"}];
        if (error) *error = setupError;
        if (completionBlock) completionBlock(NO, setupError);
        return NO;
    }
    
    // Start capture session
    [self.captureSession startRunning];
    _isCapturing = YES;
    
    NSLog(@"SysAudioCapturer: Started capturing system audio with AVCaptureSession (SampleRate: %ld, Channels: %ld, BitsPerSample: %ld)",
          (long)_sampleRate, (long)_channels, (long)_bitsPerSample);
    
    if (completionBlock) completionBlock(YES, nil);
    return YES;
}
#endif

#pragma mark - ScreenCaptureKit Implementation (macOS 13.0+)

#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
- (void)startCaptureWithScreenCaptureKit:(NSError **)error completion:(StartCaptureCompletion)completionBlock {
    __block BOOL success = NO;
    __block NSError *setupError = nil;
    // 获取当前可共享的内容（显示器、窗口、应用） 关键点：即使只录音频，也需要先获取 displays（显示器列表）
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                         onScreenWindowsOnly:NO
                                         completionHandler:^(SCShareableContent *content, NSError *getContentError) {
        if (getContentError) {
            setupError = getContentError;
            NSLog(@"SysAudioCapturer: Failed to get shareable content: %@", getContentError.localizedDescription);
            if (completionBlock) completionBlock(NO, setupError);
            return;
        }
        NSLog(@"SysAudioCapturer: [DEBUG] Total Displays Found: %lu", (unsigned long)content.displays.count);
        if (content.displays.count == 0) {
          NSLog(@"SysAudioCapturer: No displays available. User may have denied permission in the picker.");
          setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                           code:3
                                       userInfo:@{NSLocalizedDescriptionKey: @"content.displays.count == 0"}];
          if (completionBlock) completionBlock(NO, setupError);
          return;
        }
        self.contentFilter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject
                                                excludingApplications:@[]
                                              exceptingWindows:@[]];
        if (!self.contentFilter) {
            setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create content filter"}];
            if (completionBlock) completionBlock(NO, setupError);
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
        streamConfig.excludesCurrentProcessAudio = YES;

        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.colorSpaceName = kCGColorSpaceSRGB;
        streamConfig.showsCursor = YES;
        streamConfig.captureResolution = SCCaptureResolutionNominal;

        // 【关键】必须设置宽高，否则不会触发回调！
        CGSize contentSize = CGSizeMake(self.contentFilter.contentRect.size.width * self.contentFilter.pointPixelScale,
                                self.contentFilter.contentRect.size.height * self.contentFilter.pointPixelScale);
        streamConfig.width = contentSize.width;
        streamConfig.height = contentSize.height;

        NSLog(@"[SCK] Stream config: width=%.0zu, height=%.0zu, scale=%.2f",
              streamConfig.width, streamConfig.height, self.contentFilter.pointPixelScale);
        // 设置帧率
        streamConfig.minimumFrameInterval = CMTimeMake(1, (int32_t)30);
        // 实际执行捕获的流对象
        self.audioStream = [[SCStream alloc] initWithFilter:self.contentFilter
                                                 configuration:streamConfig
                                                 delegate:self];
        if (!self.audioStream) {
            setupError = [NSError errorWithDomain:@"SysAudioCapturer"
                                             code:4
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create SCStream"}];
            if (completionBlock) completionBlock(NO, setupError);
            return;
        }
        // 注册音频数据回调（在指定队列中接收 CMSampleBuffer）
        [self.audioStream addStreamOutput:self
                                     type:SCStreamOutputTypeAudio
                          sampleHandlerQueue:nil
                          error:&setupError];

        if (setupError) {
            NSLog(@"SysAudioCapturer: Failed to add stream output: %@", setupError.localizedDescription);
            if (completionBlock) completionBlock(NO, setupError);
            return;
        }
        [self.audioStream addStreamOutput:self
                                     type:SCStreamOutputTypeScreen
                          sampleHandlerQueue:nil
                                    error:&setupError];

        if (setupError) {
            NSLog(@"SysAudioCapturer: Failed to add stream output: %@", setupError.localizedDescription);
            if (completionBlock) completionBlock(NO, setupError);
            return;
        }
        // Start the stream
        [self.audioStream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (startError) {
                setupError = startError;
                NSLog(@"SysAudioCapturer: Failed to start capture: %@", startError.localizedDescription);
                if (completionBlock) completionBlock(NO, setupError);
            } else {
                self->_isCapturing = YES;
                NSLog(@"SysAudioCapturer: Started capturing system audio with ScreenCaptureKit (SampleRate: %ld, Channels: %ld, BitsPerSample: %ld)",
                      (long)self->_sampleRate, (long)self->_channels, (long)self->_bitsPerSample);
                success = YES;
                if (completionBlock) completionBlock(YES, nil);
            }

        }];
    }];
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
- (void)userDidStopStream:(SCStream*)stream NS_SWIFT_NAME(userDidStopStream(_:))
                              API_AVAILABLE(macos(14.4)) {
  NSLog(@"SysAudioCapturer: userDidStopStream");
}
- (void)contentSharingPicker:(SCContentSharingPicker*)picker
         didUpdateWithFilter:(SCContentFilter*)filter
                   forStream:(SCStream*)stream {
  NSLog(@"SysAudioCapturer: contentSharingPicker");
}
- (void)contentSharingPicker:(SCContentSharingPicker*)picker
          didCancelForStream:(SCStream*)stream {
  NSLog(@"SysAudioCapturer: contentSharingPicker");
}
- (void)contentSharingPickerStartDidFailWithError:(NSError*)error {
  NSLog(@"SysAudioCapturer: contentSharingPickerStartDidFailWithError");
}

#pragma mark - SCStreamOutput Methods

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    if (@available(macOS 13.0, *)) {
        if (type != SCStreamOutputTypeAudio) {
            return;
        }
    }
    if (!_audioCallback) {
        return;
    }
//    NSLog(@"SysAudioCapturer: didOutputSampleBuffer %ld", (long)type);
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
                   (int)asbd->mChannelsPerFrame,
                   (int)numberOfFrames,
                   _userData);
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    NSLog(@"SysAudioCapturer: AVCaptureAudioDataOutputSampleBufferDelegate called");
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
    
    NSLog(@"SysAudioCapturer: Audio data received - Length: %zu, Frames: %zu, SampleRate: %f, Channels: %u, BitsPerChannel: %u",
          totalLength, numberOfFrames, asbd->mSampleRate, asbd->mChannelsPerFrame, (unsigned int)asbd->mBitsPerChannel);
    
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
