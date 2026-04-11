#import "SysAudioTrackManager.h"
#import <AVFoundation/AVFoundation.h>
#import "RTCAudioSource+Private.h"
#import "FlutterWebRTCPlugin.h"
#include "WebRTC/RTCPeerConnectionFactory.h"
#include "WebRTC/RTCAudioSource.h"
#include "LocalAudioTrack.h"

@implementation SysAudioTrackManager {
    NSMutableArray<NSString *> *_trackOrder;
}

@synthesize audioSource = _audioSource;

#pragma mark - Singleton
+ (instancetype)sharedInstance {
    static SysAudioTrackManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SysAudioTrackManager alloc] init];
    });
    return instance;
}

#pragma mark - Initialization
- (instancetype)init {
    self = [super init];
    if (self) {
        _audioTracks = [NSMutableDictionary dictionary];
        _trackOrder = [NSMutableArray array];
        _isInitialized = NO;
        _enablePcmRecording = NO;
        _pcmFilePath = @"";
    }
    return self;
}

#pragma mark - Public Methods

- (nullable NSMutableDictionary *)getSysAudioMediaWithPlugin:(FlutterWebRTCPlugin *)plugin
                                                   deviceId:(nullable NSString *)deviceId
                                                   streamId:(nullable NSString *)streamId
                                         enablePcmRecording:(BOOL)enablePcmRecording
                                                pcmFilePath:(nullable NSString *)pcmFilePath
                                                      error:(NSError **)error {
  // Initialize if not already initialized
  if (!_isInitialized) {
    if (![self initWithPlugin:plugin deviceId:deviceId error:error]) {
      return nil;
    }
  }
  // Start capture if not already capturing
  if (![self startCapture]) {
    if (error) {
      *error = [NSError errorWithDomain:@"SysAudioTrackManager"
                                   code:-2
                               userInfo:@{NSLocalizedDescriptionKey: @"Failed to start system audio capture"}];
    }
    return nil;
  }

  // Configure PCM recording if enabled
  self.enablePcmRecording = enablePcmRecording;
  self.pcmFilePath = pcmFilePath ?: @"";

  // Create media stream
  NSMutableDictionary *resultData = [NSMutableDictionary dictionary];
  RTCMediaStream *stream = [self createSystemAudioMediaStream:plugin
                                                     streamId:streamId
                                                   resultData:resultData];
  if (!stream) {
    if (error) {
      *error = [NSError errorWithDomain:@"SysAudioTrackManager"
                                   code:-3
                               userInfo:@{NSLocalizedDescriptionKey: @"Failed to create system audio stream"}];
    }
    return nil;
  }
  NSLog(@"SysAudioTrackManager: Get sys audio stream success: %@", stream.streamId);
  return resultData;
}

- (BOOL)initWithPlugin:(FlutterWebRTCPlugin *)plugin deviceId:(nullable NSString *)deviceId error:(NSError **)error {
    if (_isInitialized) {
        NSLog(@"SysAudioTrackManager: Already initialized");
        return YES;
    }
    if (![SysAudioCapturer isSupported]) {
        if (error) {
            *error = [NSError errorWithDomain:@"SysAudioTrackManager"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"System audio capture not supported on this device"}];
        }
        return NO;
    }
    self.currentDeviceId = deviceId ?: @"";
    // Create audio capturer
    self.audioCapturer = [SysAudioCapturer sharedInstance];
    // Configure audio format
    self.audioCapturer.sampleRate = 48000;
    self.audioCapturer.channels = 2;
    self.audioCapturer.bitsPerSample = 16;
    
    // Set audio data callback to feed WebRTC
    __weak typeof(self) weakSelf = self;
    [self.audioCapturer setAudioDataCallback:^(const void *audioData,
                                               int bitsPerSample,
                               int sampleRate,
                               int numberOfChannels,
                               int numberOfFrames,
                                               void *userData) {
        [weakSelf processAudioData:audioData
                   bitsPerSample:bitsPerSample
                       sampleRate:sampleRate
                numberOfChannels:numberOfChannels
                  numberOfFrames:numberOfFrames];
    } userData:(__bridge void *)self];
    
    // Start capture with empty callback (test mode)
    NSError *captureError = nil;
    [self.audioCapturer startCapture:&captureError completion:^(BOOL success, NSError *completionError) {
        // Empty callback for test mode
        NSLog(@"SysAudioCapturer: Capture started with success: %hhd", success);
        if (!success) {
            NSLog(@"SysAudioCapturer: Capture failed: %@", completionError.localizedDescription);
        }
    }];
    
    _isInitialized = YES;
    NSLog(@"SysAudioTrackManager: Initialized successfully with device: %@", 
          deviceId ?: @"default");
    
    return YES;
}

- (BOOL)startCapture {
    if (!_isInitialized) {
        NSLog(@"SysAudioTrackManager: Not initialized");
        return NO;
    }
    
    if (self.audioCapturer && !self.audioCapturer.isCapturing) {
        NSError *error = nil;
        // Start capture with empty callback (test mode)
        [self.audioCapturer startCapture:&error completion:^(BOOL success, NSError *completionError) {
            // Empty callback for test mode
            NSLog(@"SysAudioCapturer: Capture started with success: %hhd", success);
            if (!success) {
                NSLog(@"SysAudioCapturer: Capture failed: %@", completionError.localizedDescription);
            }
        }];
        // Return YES immediately for test mode
        return YES;
    }
    return self.audioCapturer.isCapturing;
}

- (void)stopCapture {
    [self.audioCapturer stopCapture];
}

- (nullable RTCAudioTrack *)createSystemAudioTrack:(FlutterWebRTCPlugin *)plugin trackId:(nullable NSString *)trackId {
    if (!_isInitialized) {
        NSLog(@"SysAudioTrackManager: Not initialized");
        return nil;
    }
    if (!plugin.emptyPcFactory) {
        NSLog(@"SysAudioTrackManager: Peer connection factory is nil");
        return nil;
    }
    // Generate track ID if not provided
    NSString *actualTrackId = trackId.length > 0 ? trackId : [[NSUUID UUID] UUIDString];
    // Check if track already exists
    if (self.audioTracks[actualTrackId]) {
        NSLog(@"SysAudioTrackManager: Track already exists: %@", actualTrackId);
        return self.audioTracks[actualTrackId];
    }
    // Create audio source with custom ADM
    RTCAudioSource *audioSource = [plugin.emptyPcFactory audioSourceWithConstraints:nil customSource:true];
    if (!audioSource) {
        NSLog(@"SysAudioTrackManager: Failed to create audio source");
        return nil;
    }
    _audioSource = audioSource;
    // Create audio track
    RTCAudioTrack *audioTrack = [plugin.emptyPcFactory audioTrackWithSource:audioSource
                                                       trackId:actualTrackId];
    if (!audioTrack) {
        NSLog(@"SysAudioTrackManager: Failed to create audio track");
        return nil;
    }
    // Store track
    @synchronized (self) {
        self.audioTracks[actualTrackId] = audioTrack;
        [_trackOrder addObject:actualTrackId];
    }
    NSLog(@"SysAudioTrackManager: Created audio track: %@", actualTrackId);
    return audioTrack;
}

- (nullable RTCMediaStream *)createSystemAudioMediaStream:(FlutterWebRTCPlugin *)plugin
                                                 streamId:(nullable NSString *)streamId
                                             resultData:(NSMutableDictionary *)resultData {
    if (!_isInitialized) {
        NSLog(@"SysAudioTrackManager: Not initialized");
        return nil;
    }
    if (!plugin.emptyPcFactory) {
        NSLog(@"SysAudioTrackManager: Peer connection factory is nil");
        return nil;
    }
    // Create audio track
    RTCAudioTrack *audioTrack = [self createSystemAudioTrack:plugin trackId:nil];
    if (!audioTrack) {
        NSLog(@"SysAudioTrackManager: Failed to create audio track for stream");
        return nil;
    }
    // Generate stream ID if not provided
    NSString *actualStreamId = streamId.length > 0 ? streamId : [[NSUUID UUID] UUIDString];
    // Create media stream
    RTCMediaStream *mediaStream = [plugin.emptyPcFactory mediaStreamWithStreamId:actualStreamId];
    if (!mediaStream) {
        NSLog(@"SysAudioTrackManager: Failed to create media stream");
        return nil;
    }
    // Add audio track to stream
    [mediaStream addAudioTrack:audioTrack];
    // Store in plugin's local streams and tracks
    plugin.localStreams[actualStreamId] = mediaStream;
    plugin.localTracks[audioTrack.trackId] = [[LocalAudioTrack alloc] initWithTrack:audioTrack];
    // Populate result data
    if (resultData) {
        resultData[@"streamId"] = actualStreamId;
        resultData[@"ownerTag"] = @"local";
        
        // Audio tracks info
        NSMutableArray *audioTracksInfo = [NSMutableArray array];
        NSMutableDictionary *trackInfo = [NSMutableDictionary dictionary];
        trackInfo[@"id"] = audioTrack.trackId;
        trackInfo[@"label"] = audioTrack.trackId;
        trackInfo[@"kind"] = audioTrack.kind;
        trackInfo[@"enabled"] = @(audioTrack.isEnabled);
        
        // Track settings
        NSMutableDictionary *settings = [NSMutableDictionary dictionary];
        settings[@"deviceId"] = self.currentDeviceId;
        settings[@"kind"] = @"audioinput";
        settings[@"autoGainControl"] = @NO;
        settings[@"echoCancellation"] = @NO;
        settings[@"noiseSuppression"] = @NO;
        settings[@"channelCount"] = @2;
        trackInfo[@"settings"] = settings;
        
        [audioTracksInfo addObject:trackInfo];
        resultData[@"audioTracks"] = audioTracksInfo;
        resultData[@"videoTracks"] = @[];
    }
    
    NSLog(@"SysAudioTrackManager: Created media stream: %@", actualStreamId);
    return mediaStream;
}

- (void)releaseSysAudioMediaWithPlugin:(FlutterWebRTCPlugin *)plugin
                              streamId:(nullable NSString *)streamId {
    // 此方法调用之后会调用 streamDispose 移除track 和 stream
    // Dispose SysAudioTrackManager
    [self dispose];
    NSLog(@"SysAudioTrackManager: Released and disposed");
}

- (void)dispose {
    NSLog(@"SysAudioTrackManager: Disposing");
    [self stopCapture];
    @synchronized (self) {
        // Reset state
        self.audioCapturer = nil;
        self.audioTracks = [NSMutableDictionary dictionary];
        _trackOrder = [NSMutableArray array];
        _audioSource = nil;

        _isInitialized = NO;
        _enablePcmRecording = NO;
        _pcmFilePath = @"";
        _currentDeviceId = @"";
    }
}

#pragma mark - Private Methods
- (void)processAudioData:(const void *)audioData
           bitsPerSample:(int)bitsPerSample
              sampleRate:(int)sampleRate
        numberOfChannels:(int)numberOfChannels
          numberOfFrames:(int)numberOfFrames {
    if (!_isInitialized) {
        return;
    }
//    NSLog(@"processAudioData %d %d %d %d", bitsPerSample, sampleRate, numberOfChannels, numberOfFrames);
    int audioDataSize = (int)(numberOfFrames * (bitsPerSample / 8) * numberOfChannels);
    NSData *audioDataObj = [NSData dataWithBytesNoCopy:(void *)audioData
                                                length:audioDataSize
                                          freeWhenDone:NO];
    // audiosource发送数据
    [_audioSource onAudioData:audioDataObj
                bitsPerSample:bitsPerSample
                   sampleRate:sampleRate
             numberOfChannels:numberOfChannels numberOfFrames:numberOfFrames];
//    [self testGeneratePcmData];
    // Write to PCM file if recording is enabled
    if (_enablePcmRecording && _pcmFilePath.length > 0) {
        [self writePcmData:audioData 
            numberOfFrames:numberOfFrames
        numberOfChannels:numberOfChannels
           bitsPerSample:bitsPerSample];
    }
}

// --------------------------用于测试方法--------------------

- (void)writePcmData:(const void *)audioData
      numberOfFrames:(int)numberOfFrames
    numberOfChannels:(int)numberOfChannels
       bitsPerSample:(int)bitsPerSample {
    // Calculate data size
    size_t bytesPerFrame = numberOfChannels * (bitsPerSample / 8);
    size_t dataSize = numberOfFrames * bytesPerFrame;
    // Append to file
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:_pcmFilePath];
    if (!fileHandle) {
        // Create file if it doesn't exist
        [[NSData dataWithBytes:audioData length:dataSize] writeToFile:_pcmFilePath atomically:YES];
        return;
    }
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:[NSData dataWithBytes:audioData length:dataSize]];
    [fileHandle closeFile];
}

- (NSData *)testGeneratePcmData {
    // 1. 定义参数
    const int sample_rate = 48000;
    const int channels = 2;
    const int bits_per_sample = 32;
    const int duration_ms = 10; // 10毫秒

    // 2. 计算缓冲区大小
    int number_of_frames = (sample_rate * duration_ms) / 1000;
    // 字节数 = 帧数 * 通道数 * 每采样字节数
    size_t buffer_size = number_of_frames * channels * (bits_per_sample / 8);

    // 3. 分配内存 (使用 malloc 以便稍后由 NSData 接管释放)
    void *audio_buffer = malloc(buffer_size);
    if (!audio_buffer) {
        NSLog(@"内存分配失败");
        return nil;
    }

    // 4. 生成音频数据 (正弦波)
    // 将缓冲区视为 int16_t 数组 (因为 bits_per_sample 是 16)
    float *samples = (float *)audio_buffer;
    double frequency = 440.0; // A4 音符
    double two_pi = 2.0 * M_PI; // 使用 math.h 中的 M_PI 或手动定义

    for (int i = 0; i < number_of_frames; ++i) {
        // 计算正弦波值 [-1.0, 1.0]
        float value = 0.3 * sin(two_pi * frequency * i / sample_rate);

        // 转换为 16-bit 整数 [-32768, 32767]
        // 0.5 * 32767 = 16383.5，这里强制转换会截断小数部分
        float sample_val = value;

        // 写入左声道 (索引 i*2) 和 右声道 (索引 i*2+1)
        samples[i * 2]     = sample_val; // 左
        samples[i * 2 + 1] = sample_val; // 右
    }

    // 调试打印
//    NSLog(@"生成 PCM: %dHz, %d通道, %d位, %d帧, 大小: %zu字节",
//        sample_rate, channels, bits_per_sample, number_of_frames, buffer_size);
    // 5. 封装为 NSData
    // freeWhenDone: YES 表示当 NSData 对象被释放时，自动调用 free() 释放 audio_buffer
    NSData *pcmData = [NSData dataWithBytesNoCopy:audio_buffer
                                         length:buffer_size
                                   freeWhenDone:YES];
    [_audioSource onAudioData:pcmData
                    bitsPerSample:bits_per_sample
                       sampleRate:sample_rate
                 numberOfChannels:(int)channels numberOfFrames:(int)number_of_frames];
    return pcmData;
}

@end
