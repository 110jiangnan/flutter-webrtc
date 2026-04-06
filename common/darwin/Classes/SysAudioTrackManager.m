#import "SysAudioTrackManager.h"
#import <AVFoundation/AVFoundation.h>
#import "RTCAudioSource+Private.h"
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
                                               size_t numberOfChannels,
                                               size_t numberOfFrames,
                                               void *userData) {
        [weakSelf processAudioData:audioData
                   bitsPerSample:bitsPerSample
                       sampleRate:sampleRate
                numberOfChannels:numberOfChannels
                  numberOfFrames:numberOfFrames];
    } userData:nil];
    
    // Start capture
    NSError *captureError = nil;
    if (![self.audioCapturer startCapture:&captureError]) {
        if (error) {
            *error = captureError;
        }
        NSLog(@"SysAudioTrackManager: Failed to start capture: %@", captureError.localizedDescription);
        return NO;
    }
    
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
        BOOL result = [self.audioCapturer startCapture:&error];
        if (!result) {
            NSLog(@"SysAudioTrackManager: Failed to start capture: %@", error.localizedDescription);
        }
        return result;
    }
    return self.audioCapturer.isCapturing;
}

- (void)stopCapture {
    [self.audioCapturer stopCapture];
}

- (nullable RTCAudioTrack *)createSystemAudioTrack:(FlutterWebRTCPlugin *)plugin (nullable NSString *)trackId {
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
    RTCAudioTrack *audioTrack = [self createSystemAudioTrack:nil];
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
        numberOfChannels:(size_t)numberOfChannels
          numberOfFrames:(size_t)numberOfFrames {
    if (!_isInitialized) {
        return;
    }
    @synchronized (self) {
        // audiosource发送数据
        audioSource.onAudioData(audioData, bitsPerSample, sampleRate, numberOfChannels, numberOfFrames);
    }
    // Write to PCM file if recording is enabled
    if (_enablePcmRecording && _pcmFilePath.length > 0) {
        [self writePcmData:audioData 
            numberOfFrames:numberOfFrames
        numberOfChannels:numberOfChannels
           bitsPerSample:bitsPerSample];
    }
}

- (void)writePcmData:(const void *)audioData
      numberOfFrames:(size_t)numberOfFrames
    numberOfChannels:(size_t)numberOfChannels
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

@end
