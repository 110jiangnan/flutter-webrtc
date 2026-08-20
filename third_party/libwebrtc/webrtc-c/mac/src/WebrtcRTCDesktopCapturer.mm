/*
 * WebrtcRTCDesktopCapturer.mm — mac C ABI 桌面采集(照抄 darwin FlutterRTCDesktopCapturer.m 去 Flutter)。
 * 覆盖 webrtc-cli 实际使用的:
 *   webrtc_get_desktop_sources  -> getDesktopSources:result:
 *   webrtc_get_display_media    -> getDisplayMedia:result:
 * 流程保留 darwin 原逻辑; result 换 WebrtcResult; FlutterError 换 WebrtcError。
 * 桌面源事件(desktopSourceAdded 等)在 C ABI 无消费方, 已删除(darwin 走插件级 eventSink)。
 */
#import <objc/runtime.h>
#import <AppKit/AppKit.h>

#import "WebrtcPlugin.h"
#import "VideoProcessingAdapter.h"
#import "LocalVideoTrack.h"

#if TARGET_OS_OSX
static RTCDesktopMediaList* _screen = nil;
static RTCDesktopMediaList* _window = nil;
static NSArray<RTCDesktopSource*>* _captureSources;
#endif

@implementation WebrtcPlugin (RTCDesktopCapturer)

- (void)getDisplayMedia:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* mediaStreamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
  RTCVideoSource* videoSource = [self.peerConnectionFactory videoSourceForScreenCast:YES];
  NSString* trackUUID = [[NSUUID UUID] UUIDString];
  VideoProcessingAdapter *videoProcessingAdapter = [[VideoProcessingAdapter alloc] initWithRTCVideoSource:videoSource];

#if TARGET_OS_OSX
  /* example for constraints:
      {
          'audio': false,
          'video": {
              'cursor': 'always' , // 'never'
              'deviceId':  {'exact': sourceId},
              'mandatory': {
                  'frameRate': 30.0
              },
          }
      }
  */
  NSString* sourceId = nil;
  BOOL useDefaultScreen = NO;
  NSInteger fps = 30;
  id videoConstraints = constraints[@"video"];
  BOOL showCursor = YES; // 默认显示鼠标
  if ([videoConstraints isKindOfClass:[NSNumber class]] && [videoConstraints boolValue] == YES) {
    useDefaultScreen = YES;
  } else if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
    NSDictionary* deviceId = videoConstraints[@"deviceId"];
    if (deviceId != nil && [deviceId isKindOfClass:[NSDictionary class]]) {
      if (deviceId[@"exact"] != nil) {
        sourceId = deviceId[@"exact"];
        if (sourceId == nil) {
          result(@{@"error" : @"No deviceId.exact found"});
          return;
        }
      }
    } else {
      // fall back to default screen if no deviceId is specified
      useDefaultScreen = YES;
    }
    id mandatory = videoConstraints[@"mandatory"];
    if (mandatory != nil && [mandatory isKindOfClass:[NSDictionary class]]) {
      id frameRate = mandatory[@"frameRate"];
      if (frameRate != nil && [frameRate isKindOfClass:[NSNumber class]]) {
        fps = [frameRate integerValue];
      }
    }
    id cursorValue = videoConstraints[@"cursor"];
    if (cursorValue != nil && [cursorValue isKindOfClass:[NSString class]]) {
      NSString* cursorStr = (NSString*)cursorValue;
      if ([cursorStr isEqualToString:@"never"]) {
        showCursor = NO;
      } else {
        // "always", "motion", 或其他值都视为显示
        showCursor = YES;
      }
    }
  }
  RTCDesktopCapturer* desktopCapturer;
  RTCDesktopSource* source = nil;

  if (useDefaultScreen) {
    desktopCapturer = [[RTCDesktopCapturer alloc] initWithDefaultScreen:self
                                                        captureDelegate:videoProcessingAdapter
                                                             showCursor:showCursor];
  } else {
    source = [self getSourceById:sourceId];
    if (source == nil) {
      result(@{@"error" : [NSString stringWithFormat:@"No source found for id: %@", sourceId]});
      return;
    }
    desktopCapturer = [[RTCDesktopCapturer alloc] initWithSource:source
                                                        delegate:self
                                                 captureDelegate:videoProcessingAdapter
                                                      showCursor:showCursor];
  }
  [desktopCapturer startCaptureWithFPS:fps];
  NSLog(@"start desktop capture: sourceId: %@, type: %@, fps: %lu", sourceId,
        source.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window", fps);

  self.videoCapturerStopHandlers[trackUUID] = ^(CompletionHandler handler) {
    NSLog(@"stop desktop capture: sourceId: %@, type: %@, trackID %@", sourceId,
          source.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window", trackUUID);
    [desktopCapturer stopCapture];
    handler();
  };
#endif

  RTCVideoTrack* videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource
                                                                       trackId:trackUUID];
  [mediaStream addVideoTrack:videoTrack];

  LocalVideoTrack *localVideoTrack = [[LocalVideoTrack alloc] initWithTrack:videoTrack videoProcessing:videoProcessingAdapter];

  [self.localTracks setObject:localVideoTrack forKey:trackUUID];

  NSMutableArray* audioTracks = [NSMutableArray array];
  NSMutableArray* videoTracks = [NSMutableArray array];

  for (RTCVideoTrack* track in mediaStream.videoTracks) {
    [videoTracks addObject:@{
      @"id" : track.trackId,
      @"kind" : track.kind,
      @"label" : track.trackId,
      @"enabled" : @(track.isEnabled),
      @"remote" : @(YES),
      @"readyState" : @"live"
    }];
  }

  self.localStreams[mediaStreamId] = mediaStream;
  result(
      @{@"streamId" : mediaStreamId, @"audioTracks" : audioTracks, @"videoTracks" : videoTracks});
}

- (void)getDesktopSources:(NSDictionary*)argsMap result:(WebrtcResult)result {
#if TARGET_OS_OSX
  NSLog(@"getDesktopSources");

  NSArray* types = [argsMap objectForKey:@"types"];
  if (types == nil) {
    result([WebrtcError errorWithCode:@"ERROR" message:@"types is required" details:nil]);
    return;
  }

  if (![self buildDesktopSourcesListWithTypes:types forceReload:YES result:result]) {
    NSLog(@"getDesktopSources failed.");
    return;
  }

  NSMutableArray* sources = [NSMutableArray array];
  NSEnumerator* enumerator = [_captureSources objectEnumerator];
  RTCDesktopSource* object;
  while ((object = enumerator.nextObject) != nil) {
    [sources addObject:@{
      @"id" : object.sourceId,
      @"name" : object.name,
      @"thumbnailSize" : @{@"width" : @0, @"height" : @0},
      @"type" : object.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window",
    }];
  }
  result(@{@"sources" : sources});
#endif
}

#if TARGET_OS_OSX
- (RTCDesktopSource*)getSourceById:(NSString*)sourceId {
  NSEnumerator* enumerator = [_captureSources objectEnumerator];
  RTCDesktopSource* object;
  while ((object = enumerator.nextObject) != nil) {
    if ([sourceId isEqualToString:object.sourceId]) {
      return object;
    }
  }
  return nil;
}

- (BOOL)buildDesktopSourcesListWithTypes:(NSArray*)types
                             forceReload:(BOOL)forceReload
                                  result:(WebrtcResult)result {
  BOOL captureWindow = NO;
  BOOL captureScreen = NO;
  _captureSources = [NSMutableArray array];

  NSEnumerator* typesEnumerator = [types objectEnumerator];
  NSString* type;
  while ((type = typesEnumerator.nextObject) != nil) {
    if ([type isEqualToString:@"screen"]) {
      captureScreen = YES;
    } else if ([type isEqualToString:@"window"]) {
      captureWindow = YES;
    } else {
      result([WebrtcError errorWithCode:@"ERROR" message:@"Invalid type" details:nil]);
      return NO;
    }
  }

  if (!captureWindow && !captureScreen) {
    result([WebrtcError errorWithCode:@"ERROR"
                               message:@"At least one type is required"
                               details:nil]);
    return NO;
  }

  if (captureWindow) {
    if (!_window)
      _window = [[RTCDesktopMediaList alloc] initWithType:RTCDesktopSourceTypeWindow delegate:self];
    [_window UpdateSourceList:forceReload updateAllThumbnails:YES];
    NSArray<RTCDesktopSource*>* sources = [_window getSources];
    _captureSources = [_captureSources arrayByAddingObjectsFromArray:sources];
  }
  if (captureScreen) {
    if (!_screen)
      _screen = [[RTCDesktopMediaList alloc] initWithType:RTCDesktopSourceTypeScreen delegate:self];
    [_screen UpdateSourceList:forceReload updateAllThumbnails:YES];
    NSArray<RTCDesktopSource*>* sources = [_screen getSources];
    _captureSources = [_captureSources arrayByAddingObjectsFromArray:sources];
  }
  NSLog(@"captureSources: %lu", [_captureSources count]);
  return YES;
}

#pragma mark - RTCDesktopCapturerDelegate delegate

- (void)didSourceCaptureStart:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCaptureStart");
}

- (void)didSourceCapturePaused:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCapturePaused");
}

- (void)didSourceCaptureStop:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCaptureStop");
}

- (void)didSourceCaptureError:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCaptureError");
}

#endif

@end
