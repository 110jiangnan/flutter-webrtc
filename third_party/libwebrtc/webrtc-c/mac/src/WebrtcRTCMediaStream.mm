/* WebrtcRTCMediaStream.mm — 照抄 FlutterRTCMediaStream.m, 去 Flutter。
 * category: WebrtcPlugin (RTCMediaStream)，业务方法与 darwin 逐位一致；
 * FlutterResult → WebrtcResult，FlutterError → WebrtcError。
 * iOS 分支(#if TARGET_OS_IPHONE 内)在 mac 上被预处理器剔除，保留以保照抄度。
 */
#import <objc/runtime.h>
#import "CameraUtils.h"
#import "WebrtcPlugin.h"
#import "VideoProcessingAdapter.h"
#import "LocalVideoTrack.h"
#import "LocalAudioTrack.h"

@implementation RTCMediaStreamTrack (Flutter)

- (id)settings {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setSettings:(id)settings {
  objc_setAssociatedObject(self, @selector(settings), settings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

@implementation AVCaptureDevice (Flutter)

- (NSString*)positionString {
  switch (self.position) {
    case AVCaptureDevicePositionUnspecified:
      return @"unspecified";
    case AVCaptureDevicePositionBack:
      return @"back";
    case AVCaptureDevicePositionFront:
      return @"front";
  }
  return nil;
}

@end

/* getUserVideo / iOS 控制方法会用到的状态, 不在 WebrtcPlugin.h 主接口里,
 * 用关联对象承载(CameraUtils 同款做法), 避免跨 TU 重复合成 ivar。 */
@interface WebrtcPlugin (MediaStreamState)
@property(nonatomic, strong, nullable) RTCCameraVideoCapturer* videoCapturer;
@property(nonatomic) BOOL _usingFrontCamera;
@property(nonatomic) NSInteger _lastTargetWidth;
@property(nonatomic) NSInteger _lastTargetHeight;
@property(nonatomic) NSInteger _lastTargetFps;
@end

@implementation WebrtcPlugin (MediaStreamState)
static char kVideoCapturerKey;
static char kUsingFrontCameraKey;
static char kLastTargetWidthKey;
static char kLastTargetHeightKey;
static char kLastTargetFpsKey;

- (RTCCameraVideoCapturer*)videoCapturer {
  return objc_getAssociatedObject(self, &kVideoCapturerKey);
}
- (void)setVideoCapturer:(RTCCameraVideoCapturer*)videoCapturer {
  objc_setAssociatedObject(self, &kVideoCapturerKey, videoCapturer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (BOOL)_usingFrontCamera {
  return [objc_getAssociatedObject(self, &kUsingFrontCameraKey) boolValue];
}
- (void)set_usingFrontCamera:(BOOL)usingFrontCamera {
  objc_setAssociatedObject(self, &kUsingFrontCameraKey, @(usingFrontCamera), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSInteger)_lastTargetWidth {
  return [objc_getAssociatedObject(self, &kLastTargetWidthKey) integerValue];
}
- (void)set_lastTargetWidth:(NSInteger)w {
  objc_setAssociatedObject(self, &kLastTargetWidthKey, @(w), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSInteger)_lastTargetHeight {
  return [objc_getAssociatedObject(self, &kLastTargetHeightKey) integerValue];
}
- (void)set_lastTargetHeight:(NSInteger)h {
  objc_setAssociatedObject(self, &kLastTargetHeightKey, @(h), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSInteger)_lastTargetFps {
  return [objc_getAssociatedObject(self, &kLastTargetFpsKey) integerValue];
}
- (void)set_lastTargetFps:(NSInteger)fps {
  objc_setAssociatedObject(self, &kLastTargetFpsKey, @(fps), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

@implementation WebrtcPlugin (RTCMediaStream)

typedef void (^NavigatorUserMediaErrorCallback)(NSString* errorType, NSString* errorMessage);
typedef void (^NavigatorUserMediaSuccessCallback)(RTCMediaStream* mediaStream);

- (NSDictionary*)defaultVideoConstraints {
    return @{@"minWidth" : @"1280", @"minHeight" : @"720", @"minFrameRate" : @"30"};
}

- (NSDictionary*)defaultAudioConstraints {
    return @{};
}

- (RTCMediaConstraints*)defaultMediaStreamConstraints {
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc] initWithMandatoryConstraints:[self defaultVideoConstraints]
                                            optionalConstraints:nil];
  return constraints;
}

- (NSArray<AVCaptureDevice*> *) captureDevices {
    if (@available(iOS 13.0, macOS 10.15, macCatalyst 14.0, tvOS 17.0, *)) {
        NSArray<AVCaptureDeviceType> *deviceTypes = @[
#if TARGET_OS_IPHONE
            AVCaptureDeviceTypeBuiltInTripleCamera,
            AVCaptureDeviceTypeBuiltInDualCamera,
            AVCaptureDeviceTypeBuiltInDualWideCamera,
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
            AVCaptureDeviceTypeBuiltInTelephotoCamera,
            AVCaptureDeviceTypeBuiltInUltraWideCamera,
#else
            AVCaptureDeviceTypeBuiltInWideAngleCamera,
#endif
        ];

#if !defined(TARGET_OS_IPHONE)
        if (@available(macOS 13.0, *)) {
            deviceTypes = [deviceTypes arrayByAddingObject:AVCaptureDeviceTypeDeskViewCamera];
        }
#endif

        if (@available(iOS 17.0, macOS 14.0, tvOS 17.0, *)) {
            deviceTypes = [deviceTypes arrayByAddingObjectsFromArray: @[
                AVCaptureDeviceTypeContinuityCamera,
                AVCaptureDeviceTypeExternal,
            ]];
        }

        return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                                      mediaType:AVMediaTypeVideo
                                                                       position:AVCaptureDevicePositionUnspecified].devices;
    }
    return @[];
}

- (void)getUserAudio:(NSDictionary*)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream*)mediaStream {
  id audioConstraints = constraints[@"audio"];
  NSString* audioDeviceId = @"";
  RTCMediaConstraints *rtcConstraints;
  if ([audioConstraints isKindOfClass:[NSDictionary class]]) {
    // constraints.audio.deviceId
    NSString* deviceId = audioConstraints[@"deviceId"];

    if (deviceId) {
      audioDeviceId = deviceId;
    }

    rtcConstraints = [self parseMediaConstraints:audioConstraints];
    // constraints.audio.optional.sourceId
    id optionalConstraints = audioConstraints[@"optional"];
    if (optionalConstraints && [optionalConstraints isKindOfClass:[NSArray class]] &&
        !deviceId) {
      NSArray* options = optionalConstraints;
      for (id item in options) {
        if ([item isKindOfClass:[NSDictionary class]]) {
          NSString* sourceId = ((NSDictionary*)item)[@"sourceId"];
          if (sourceId) {
            audioDeviceId = sourceId;
          }
        }
      }
    }
  } else {
      rtcConstraints = [self parseMediaConstraints:[self defaultAudioConstraints]];
  }

#if !defined(TARGET_OS_IPHONE)
  if (audioDeviceId != nil) {
    [self selectAudioInput:audioDeviceId result:nil];
  }
#endif

  NSString* trackId = [[NSUUID UUID] UUIDString];
  RTCAudioSource *audioSource = [self.peerConnectionFactory audioSourceWithConstraints:rtcConstraints];
  RTCAudioTrack* audioTrack = [self.peerConnectionFactory audioTrackWithSource:audioSource trackId:trackId];
  LocalAudioTrack *localAudioTrack = [[LocalAudioTrack alloc] initWithTrack:audioTrack];

  audioTrack.settings = @{
    @"deviceId" : audioDeviceId,
    @"kind" : @"audioinput",
    @"autoGainControl" : @YES,
    @"echoCancellation" : @YES,
    @"noiseSuppression" : @YES,
    @"channelCount" : @1,
    @"latency" : @0,
  };

  [mediaStream addAudioTrack:audioTrack];

  [self.localTracks setObject:localAudioTrack forKey:trackId];

  [self ensureAudioSession];

  successCallback(mediaStream);
}

/* getUserMedia:result: —— 对应 C ABI webrtc_get_user_media */
- (void)getUserMedia:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* mediaStreamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];

  [self getUserMedia:constraints
      successCallback:^(RTCMediaStream* mediaStream) {
        NSString* mediaStreamId = mediaStream.streamId;

        NSMutableArray* audioTracks = [NSMutableArray array];
        NSMutableArray* videoTracks = [NSMutableArray array];

        for (RTCAudioTrack* track in mediaStream.audioTracks) {
          [audioTracks addObject:@{
            @"id" : track.trackId,
            @"kind" : track.kind,
            @"label" : track.trackId,
            @"enabled" : @(track.isEnabled),
            @"remote" : @(YES),
            @"readyState" : @"live",
            @"settings" : track.settings
          }];
        }

        for (RTCVideoTrack* track in mediaStream.videoTracks) {
          [videoTracks addObject:@{
            @"id" : track.trackId,
            @"kind" : track.kind,
            @"label" : track.trackId,
            @"enabled" : @(track.isEnabled),
            @"remote" : @(YES),
            @"readyState" : @"live",
            @"settings" : track.settings
          }];
        }

        self.localStreams[mediaStreamId] = mediaStream;
        result(@{
          @"streamId" : mediaStreamId,
          @"audioTracks" : audioTracks,
          @"videoTracks" : videoTracks
        });
      }
      errorCallback:^(NSString* errorType, NSString* errorMessage) {
        result([WebrtcError errorWithCode:[NSString stringWithFormat:@"Error %@", errorType]
                                  message:errorMessage
                                  details:nil]);
      }
      mediaStream:mediaStream];
}

- (void)getUserMedia:(NSDictionary*)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream*)mediaStream {
  if (mediaStream.audioTracks.count == 0) {
    id audioConstraints = constraints[@"audio"];
    BOOL constraintsIsDictionary = [audioConstraints isKindOfClass:[NSDictionary class]];
    if (audioConstraints && (constraintsIsDictionary || [audioConstraints boolValue])) {
      [self requestAccessForMediaType:AVMediaTypeAudio
                          constraints:constraints
                      successCallback:successCallback
                        errorCallback:errorCallback
                          mediaStream:mediaStream];
      return;
    }
  }

  if (mediaStream.videoTracks.count == 0) {
    id videoConstraints = constraints[@"video"];
    if (videoConstraints) {
      BOOL requestAccessForVideo = [videoConstraints isKindOfClass:[NSNumber class]]
                                       ? [videoConstraints boolValue]
                                       : [videoConstraints isKindOfClass:[NSDictionary class]];
#if !TARGET_IPHONE_SIMULATOR
      if (requestAccessForVideo) {
        [self requestAccessForMediaType:AVMediaTypeVideo
                            constraints:constraints
                        successCallback:successCallback
                          errorCallback:errorCallback
                            mediaStream:mediaStream];
        return;
      }
#endif
    }
  }

  successCallback(mediaStream);
}

- (int)getConstrainInt:(NSDictionary*)constraints forKey:(NSString*)key {
  if (![constraints isKindOfClass:[NSDictionary class]]) {
    return 0;
  }

  id constraint = constraints[key];
  if ([constraint isKindOfClass:[NSNumber class]]) {
    return [constraint intValue];
  } else if ([constraint isKindOfClass:[NSString class]]) {
    int possibleValue = [constraint intValue];
    if (possibleValue != 0) {
      return possibleValue;
    }
  } else if ([constraint isKindOfClass:[NSDictionary class]]) {
    id idealConstraint = constraint[@"ideal"];
    if ([idealConstraint isKindOfClass:[NSString class]]) {
      int possibleValue = [idealConstraint intValue];
      if (possibleValue != 0) {
        return possibleValue;
      }
    }
  }

  return 0;
}

- (void)getUserVideo:(NSDictionary*)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream*)mediaStream {
  id videoConstraints = constraints[@"video"];
  AVCaptureDevice* videoDevice;
  NSString* videoDeviceId = nil;
  NSString* facingMode = nil;
  NSArray<AVCaptureDevice*>* captureDevices = [self captureDevices];

  if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
    NSString* deviceId = videoConstraints[@"deviceId"];

    if (deviceId) {
        for (AVCaptureDevice *device in captureDevices) {
            if( [deviceId isEqualToString:device.uniqueID]) {
                videoDevice = device;
                videoDeviceId = deviceId;
            }
        }
    }

    id optionalVideoConstraints = videoConstraints[@"optional"];
    if (optionalVideoConstraints && [optionalVideoConstraints isKindOfClass:[NSArray class]] &&
        !videoDevice) {
      NSArray* options = optionalVideoConstraints;
      for (id item in options) {
        if ([item isKindOfClass:[NSDictionary class]]) {
          NSString* sourceId = ((NSDictionary*)item)[@"sourceId"];
          if (sourceId) {
              for (AVCaptureDevice *device in captureDevices) {
                  if( [sourceId isEqualToString:device.uniqueID]) {
                      videoDevice = device;
                      videoDeviceId = sourceId;
                  }
              }
            if (videoDevice) {
              break;
            }
          }
        }
      }
    }

    if (!videoDevice) {
      facingMode = videoConstraints[@"facingMode"];
      if (facingMode && [facingMode isKindOfClass:[NSString class]]) {
        AVCaptureDevicePosition position;
        if ([facingMode isEqualToString:@"environment"]) {
          self._usingFrontCamera = NO;
          position = AVCaptureDevicePositionBack;
        } else if ([facingMode isEqualToString:@"user"]) {
          self._usingFrontCamera = YES;
          position = AVCaptureDevicePositionFront;
        } else {
          self._usingFrontCamera = NO;
          position = AVCaptureDevicePositionUnspecified;
        }
        videoDevice = [self findDeviceForPosition:position];
      }
    }
  }

  if ([videoConstraints isKindOfClass:[NSNumber class]]) {
    videoConstraints = @{@"mandatory": [self defaultVideoConstraints]};
  }

  NSInteger targetWidth = 0;
  NSInteger targetHeight = 0;
  NSInteger targetFps = 0;

  if (!videoDevice) {
    videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  }

  int possibleWidth = [self getConstrainInt:videoConstraints forKey:@"width"];
  if (possibleWidth != 0) {
    targetWidth = possibleWidth;
  }

  int possibleHeight = [self getConstrainInt:videoConstraints forKey:@"height"];
  if (possibleHeight != 0) {
    targetHeight = possibleHeight;
  }

  int possibleFps = [self getConstrainInt:videoConstraints forKey:@"frameRate"];
  if (possibleFps != 0) {
    targetFps = possibleFps;
  }

  id mandatory =
      [videoConstraints isKindOfClass:[NSDictionary class]] ? videoConstraints[@"mandatory"] : nil;

  if (mandatory && [mandatory isKindOfClass:[NSDictionary class]]) {
    id widthConstraint = mandatory[@"minWidth"];
    if ([widthConstraint isKindOfClass:[NSString class]] ||
        [widthConstraint isKindOfClass:[NSNumber class]]) {
      int possibleWidth = [widthConstraint intValue];
      if (possibleWidth != 0) {
        targetWidth = possibleWidth;
      }
    }
    id heightConstraint = mandatory[@"minHeight"];
    if ([heightConstraint isKindOfClass:[NSString class]] ||
        [heightConstraint isKindOfClass:[NSNumber class]]) {
      int possibleHeight = [heightConstraint intValue];
      if (possibleHeight != 0) {
        targetHeight = possibleHeight;
      }
    }
    id fpsConstraint = mandatory[@"minFrameRate"];
    if ([fpsConstraint isKindOfClass:[NSString class]] ||
        [fpsConstraint isKindOfClass:[NSNumber class]]) {
      int possibleFps = [fpsConstraint intValue];
      if (possibleFps != 0) {
        targetFps = possibleFps;
      }
    }
  }

  if (videoDevice) {
    RTCVideoSource* videoSource = [self.peerConnectionFactory videoSource];
#if TARGET_OS_OSX
    if (self.videoCapturer) {
      [self.videoCapturer stopCapture];
    }
#endif

    VideoProcessingAdapter *videoProcessingAdapter = [[VideoProcessingAdapter alloc] initWithRTCVideoSource:videoSource];
    self.videoCapturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:videoProcessingAdapter];

    AVCaptureDeviceFormat* selectedFormat = [self selectFormatForDevice:videoDevice
                                                            targetWidth:targetWidth
                                                           targetHeight:targetHeight];

    CMVideoDimensions selectedDimension = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription);
    NSInteger selectedWidth = (NSInteger) selectedDimension.width;
    NSInteger selectedHeight = (NSInteger) selectedDimension.height;
    NSInteger selectedFps = [self selectFpsForFormat:selectedFormat targetFps:targetFps];

    self._lastTargetFps = selectedFps;
    self._lastTargetWidth = targetWidth;
    self._lastTargetHeight = targetHeight;

    NSLog(@"target format %ldx%ld, targetFps: %ld, selected format: %ldx%ld, selected fps %ld", targetWidth, targetHeight, targetFps, selectedWidth, selectedHeight, selectedFps);

    if ([videoDevice lockForConfiguration:NULL]) {
      @try {
        videoDevice.activeVideoMaxFrameDuration = CMTimeMake(1, (int32_t)selectedFps);
        videoDevice.activeVideoMinFrameDuration = CMTimeMake(1, (int32_t)selectedFps);
      } @catch (NSException* exception) {
        NSLog(@"Failed to set active frame rate!\n User info:%@", exception.userInfo);
      }
      [videoDevice unlockForConfiguration];
    }

    [self.videoCapturer startCaptureWithDevice:videoDevice
                                        format:selectedFormat
                                           fps:selectedFps
                             completionHandler:^(NSError* error) {
                               if (error) {
                                 NSLog(@"Start capture error: %@", [error localizedDescription]);
                               }
                             }];

    NSString* trackUUID = [[NSUUID UUID] UUIDString];
    RTCVideoTrack* videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource
                                                                        trackId:trackUUID];
    LocalVideoTrack *localVideoTrack = [[LocalVideoTrack alloc] initWithTrack:videoTrack videoProcessing:videoProcessingAdapter];

    __weak RTCCameraVideoCapturer* capturer = self.videoCapturer;
    self.videoCapturerStopHandlers[videoTrack.trackId] = ^(CompletionHandler handler) {
      NSLog(@"Stop video capturer, trackID %@", videoTrack.trackId);
      [capturer stopCaptureWithCompletionHandler:handler];
    };

    if (!videoDeviceId) {
      videoDeviceId = videoDevice.uniqueID;
    }

    if (!facingMode) {
      facingMode = videoDevice.position == AVCaptureDevicePositionBack    ? @"environment"
                   : videoDevice.position == AVCaptureDevicePositionFront ? @"user"
                                                                          : @"unspecified";
    }

    videoTrack.settings = @{
      @"deviceId" : videoDeviceId,
      @"kind" : @"videoinput",
      @"width" : [NSNumber numberWithInteger:selectedWidth],
      @"height" : [NSNumber numberWithInteger:selectedHeight],
      @"frameRate" : [NSNumber numberWithInteger:selectedFps],
      @"facingMode" : facingMode,
    };

    [mediaStream addVideoTrack:videoTrack];

    [self.localTracks setObject:localVideoTrack forKey:trackUUID];

    successCallback(mediaStream);
  } else {
    errorCallback(@"OverconstrainedError", /* errorMessage */ nil);
  }
}

- (void)mediaStreamRelease:(RTCMediaStream*)stream {
  if (stream) {
    for (RTCVideoTrack* track in stream.videoTracks) {
      [self.localTracks removeObjectForKey:track.trackId];
    }
    for (RTCAudioTrack* track in stream.audioTracks) {
      [self.localTracks removeObjectForKey:track.trackId];
    }
    [self.localStreams removeObjectForKey:stream.streamId];
  }
}

- (void)requestAccessForMediaType:(NSString*)mediaType
                      constraints:(NSDictionary*)constraints
                  successCallback:(NavigatorUserMediaSuccessCallback)successCallback
                    errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
                      mediaStream:(RTCMediaStream*)mediaStream {
  if (mediaType == AVMediaTypeVideo && [self captureDevices].count == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      errorCallback(@"DOMException", @"NotFoundError");
    });
    return;
  }

#if TARGET_OS_OSX
  if (@available(macOS 10.14, *)) {
#endif
    [AVCaptureDevice requestAccessForMediaType:mediaType
                             completionHandler:^(BOOL granted) {
                               dispatch_async(dispatch_get_main_queue(), ^{
                                 if (granted) {
                                   NavigatorUserMediaSuccessCallback scb =
                                       ^(RTCMediaStream* mediaStream) {
                                         [self getUserMedia:constraints
                                             successCallback:successCallback
                                               errorCallback:errorCallback
                                                 mediaStream:mediaStream];
                                       };

                                   if (mediaType == AVMediaTypeAudio) {
                                     [self getUserAudio:constraints
                                         successCallback:scb
                                           errorCallback:errorCallback
                                             mediaStream:mediaStream];
                                   } else if (mediaType == AVMediaTypeVideo) {
                                     [self getUserVideo:constraints
                                         successCallback:scb
                                           errorCallback:errorCallback
                                             mediaStream:mediaStream];
                                   }
                                 } else {
                                   errorCallback(@"DOMException", @"NotAllowedError");
                                 }
                               });
                             }];
#if TARGET_OS_OSX
  } else {
    NavigatorUserMediaSuccessCallback scb = ^(RTCMediaStream* mediaStream) {
      [self getUserMedia:constraints
          successCallback:successCallback
            errorCallback:errorCallback
              mediaStream:mediaStream];
    };
    if (mediaType == AVMediaTypeAudio) {
      [self getUserAudio:constraints
          successCallback:scb
            errorCallback:errorCallback
              mediaStream:mediaStream];
    } else if (mediaType == AVMediaTypeVideo) {
      [self getUserVideo:constraints
          successCallback:scb
            errorCallback:errorCallback
              mediaStream:mediaStream];
    }
  }
#endif
}

/* createLocalMediaStream:result: —— 对应 C ABI webrtc_create_local_media_stream */
- (void)createLocalMediaStream:(WebrtcResult)result {
  NSString* mediaStreamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];

  self.localStreams[mediaStreamId] = mediaStream;
  result(@{@"streamId" : [mediaStream streamId]});
}

/* getSources:result: —— 对应 C ABI webrtc_get_sources */
- (void)getSources:(WebrtcResult)result {
  NSMutableArray* sources = [NSMutableArray array];
  NSArray* videoDevices =  [self captureDevices];
  for (AVCaptureDevice* device in videoDevices) {
    [sources addObject:@{
      @"facing" : device.positionString,
      @"deviceId" : device.uniqueID,
      @"label" : device.localizedName,
      @"kind" : @"videoinput",
    }];
  }
#if TARGET_OS_IPHONE

  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  for (AVAudioSessionPortDescription* port in session.session.availableInputs) {
    [sources addObject:@{
      @"deviceId" : port.UID,
      @"label" : port.portName,
      @"groupId" : port.portType,
      @"kind" : @"audioinput",
    }];
  }

  for (AVAudioSessionPortDescription* port in session.currentRoute.outputs) {
    if (session.currentRoute.outputs.count == 1 && ![port.UID isEqualToString:@"Speaker"]) {
      [sources addObject:@{
        @"deviceId" : @"Speaker",
        @"label" : @"Speaker",
        @"groupId" : @"Speaker",
        @"kind" : @"audiooutput",
      }];
    }
    [sources addObject:@{
      @"deviceId" : port.UID,
      @"label" : port.portName,
      @"groupId" : port.portType,
      @"kind" : @"audiooutput",
    }];
  }
#endif
#if TARGET_OS_OSX
  RTCAudioDeviceModule* audioDeviceModule = [self.peerConnectionFactory audioDeviceModule];

  NSArray* inputDevices = [audioDeviceModule inputDevices];
  for (RTCIODevice* device in inputDevices) {
    [sources addObject:@{
      @"deviceId" : device.deviceId,
      @"label" : device.name,
      @"kind" : @"audioinput",
    }];
  }

  NSArray* outputDevices = [audioDeviceModule outputDevices];
  for (RTCIODevice* device in outputDevices) {
    [sources addObject:@{
      @"deviceId" : device.deviceId,
      @"label" : device.name,
      @"kind" : @"audiooutput",
    }];
  }
#endif
  result(@{@"sources" : sources});
}

/* selectAudioInput:deviceId result: —— 对应 C ABI webrtc_select_audio_input */
- (void)selectAudioInput:(NSString*)deviceId result:(WebrtcResult)result {
#if TARGET_OS_OSX
  RTCAudioDeviceModule* audioDeviceModule = [self.peerConnectionFactory audioDeviceModule];
  NSArray* inputDevices = [audioDeviceModule inputDevices];
  for (RTCIODevice* device in inputDevices) {
    if ([deviceId isEqualToString:device.deviceId]) {
      [audioDeviceModule setInputDevice:device];
      if (result)
        result(nil);
      return;
    }
  }
#endif
#if TARGET_OS_IPHONE
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  for (AVAudioSessionPortDescription* port in session.session.availableInputs) {
    if ([port.UID isEqualToString:deviceId]) {
      if (self.preferredInput != port.portType) {
        self.preferredInput = port.portType;
        [AudioUtils selectAudioInput:self.preferredInput];
      }
      break;
    }
  }
  if (result)
    result(nil);
#endif
  if (result)
    result([WebrtcError errorWithCode:@"selectAudioInputFailed"
                              message:[NSString stringWithFormat:@"Error: deviceId not found!"]
                              details:nil]);
}

/* selectAudioOutput: —— 对应 C ABI webrtc_select_audio_output(播放设备)。
 * 照抄 darwin FlutterRTCMediaStream.m selectAudioOutput:; 桌面走 RTCAudioDeviceModule 输出设备。 */
- (void)selectAudioOutput:(NSString*)deviceId result:(WebrtcResult)result {
#if TARGET_OS_OSX
  RTCAudioDeviceModule* audioDeviceModule = [self.peerConnectionFactory audioDeviceModule];
  NSArray* outputDevices = [audioDeviceModule outputDevices];
  for (RTCIODevice* device in outputDevices) {
    if ([deviceId isEqualToString:device.deviceId]) {
      [audioDeviceModule setOutputDevice:device];
      if (result) result(nil);
      return;
    }
  }
#endif
#if TARGET_OS_IPHONE
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  NSError* setCategoryError = nil;

  if ([deviceId isEqualToString:@"Speaker"]) {
    [session.session overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_Speaker
                                       error:&setCategoryError];
  } else {
    [session.session overrideOutputAudioPort:kAudioSessionOverrideAudioRoute_None
                                       error:&setCategoryError];
  }

  if (setCategoryError == nil) {
    if (result) result(nil);
    return;
  }

  if (result)
    result([WebrtcError
        errorWithCode:@"selectAudioOutputFailed"
              message:[NSString
                          stringWithFormat:@"Error: %@", [setCategoryError localizedFailureReason]]
              details:nil]);
#endif
  if (result)
    result([WebrtcError errorWithCode:@"selectAudioOutputFailed"
                              message:[NSString stringWithFormat:@"Error: deviceId not found!"]
                              details:nil]);
}

- (void)mediaStreamTrackRelease:(RTCMediaStream*)mediaStream track:(RTCMediaStreamTrack*)track {
  if (mediaStream && track) {
    track.isEnabled = NO;
    if ([track.kind isEqualToString:@"audio"]) {
      [mediaStream removeAudioTrack:(RTCAudioTrack*)track];
    } else if ([track.kind isEqualToString:@"video"]) {
      [mediaStream removeVideoTrack:(RTCVideoTrack*)track];
    }
  }
}

/* mediaStreamTrackStop: —— 对应 C ABI webrtc_media_stream_track_dispose */
- (void)mediaStreamTrackStop:(RTCMediaStreamTrack*)track {
  if (track) {
    track.isEnabled = NO;
    [self.localTracks removeObjectForKey:track.trackId];
  }
}

/* mediaStreamGetTracks: —— 对应 C ABI webrtc_media_stream_get_tracks。
 * 返回与 win/linux ABI 相同的 {"audioTracks":[...],"videoTracks":[...]},
 * 每个 track 用 mediaTrackToMap (id/label/kind/enabled/remote/readyState)。
 * 注意: 不写入 localTracks —— 本方法只读流轨迹; 本地轨迹由 getUserMedia 创建时
 * 已用 LocalAudioTrack/LocalVideoTrack 包装登记。 */
- (void)mediaStreamGetTracks:(NSString*)streamId result:(WebrtcResult)result {
  if (!streamId || streamId.length == 0) {
    if (result) result([WebrtcError errorWithCode:@"mediaStreamGetTracksFailed"
                                          message:@"streamId is nil"
                                          details:nil]);
    return;
  }
  RTCMediaStream* stream = [self streamForId:streamId peerConnectionId:nil];
  if (stream == nil) {
    if (result) result([WebrtcError errorWithCode:@"mediaStreamGetTracksFailed"
                                          message:@"Media stream not found"
                                          details:nil]);
    return;
  }
  NSMutableArray* audioTracks = [NSMutableArray array];
  for (RTCMediaStreamTrack* track in stream.audioTracks) {
    [audioTracks addObject:[self mediaTrackToMap:track]];
  }
  NSMutableArray* videoTracks = [NSMutableArray array];
  for (RTCMediaStreamTrack* track in stream.videoTracks) {
    [videoTracks addObject:[self mediaTrackToMap:track]];
  }
  if (result)
    result(@{@"audioTracks" : audioTracks, @"videoTracks" : videoTracks});
}

@end
