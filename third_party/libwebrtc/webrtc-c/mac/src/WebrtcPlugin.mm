/* WebrtcPlugin.mm — mac 独立 C ABI 的插件实现。
 *
 * 照抄自 common/darwin/Classes/FlutterWebRTCPlugin.m，去掉 Flutter：
 *   - 仅保留 webrtc-cli 用的 38 个 webrtc_* C 函数对应的业务方法；
 *   - FlutterResult → WebrtcResult(C 函数指针包装)；FlutterEventSink → WebrtcEventCallback；
 *   - 方法/字段名与 darwin 保持一致。
 * 本文件 = 单例中枢 + JSON/C 桥 + 顶层 C ABI 入口层。
 */
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCFieldTrials.h>
#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCCallbackLogger.h>
#import <objc/runtime.h>

#import "WebrtcPlugin.h"
#import "WebrtcRTCPeerConnection.h"
#import "WebrtcRTCDataChannel.h"
#import "WebrtcRTCDesktopCapturer.h"
#import "SysAudioTrackManager.h"
#import "AudioManager.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

/* 照抄 darwin: 视频编解码器工厂(提升 H264 profile-level-id 到 5.1) */
@interface VideoEncoderFactory : RTCDefaultVideoEncoderFactory
@end
@interface VideoDecoderFactory : RTCDefaultVideoDecoderFactory
@end
@interface VideoEncoderFactorySimulcast : RTCVideoEncoderFactorySimulcast
@end

static NSArray<RTC_OBJC_TYPE(RTCVideoCodecInfo)*>* motifyH264ProfileLevelId(
    NSArray<RTC_OBJC_TYPE(RTCVideoCodecInfo)*>* codecs) {
  NSMutableArray* newCodecs = [[NSMutableArray alloc] init];
  NSInteger count = codecs.count;
  for (NSInteger i = 0; i < count; i++) {
    RTC_OBJC_TYPE(RTCVideoCodecInfo)* info = [codecs objectAtIndex:i];
    if ([info.name isEqualToString:kRTCVideoCodecH264Name]) {
      NSString* hexString = info.parameters[@"profile-level-id"];
      RTCH264ProfileLevelId* profileLevelId = [[RTCH264ProfileLevelId alloc] initWithHexString:hexString];
      if (profileLevelId.level < RTCH264Level5_1) {
        RTCH264ProfileLevelId* newProfileLevelId =
            [[RTCH264ProfileLevelId alloc] initWithProfile:profileLevelId.profile
                                                      level:RTCH264Level5_1];
        NSMutableDictionary* parametersCopy = [[NSMutableDictionary alloc] init];
        [parametersCopy addEntriesFromDictionary:info.parameters];
        [parametersCopy setObject:[newProfileLevelId hexString] forKey:@"profile-level-id"];
        [newCodecs insertObject:[[RTCVideoCodecInfo alloc] initWithName:kRTCVideoCodecH264Name
                                                              parameters:parametersCopy]
                         atIndex:i];
      } else {
        [newCodecs insertObject:info atIndex:i];
      }
    } else {
      [newCodecs insertObject:info atIndex:i];
    }
  }
  return newCodecs;
}

@implementation VideoEncoderFactory
- (NSArray<RTC_OBJC_TYPE(RTCVideoCodecInfo)*>*)supportedCodecs {
  return motifyH264ProfileLevelId([super supportedCodecs]);
}
@end
@implementation VideoDecoderFactory
- (NSArray<RTC_OBJC_TYPE(RTCVideoCodecInfo)*>*)supportedCodecs {
  return motifyH264ProfileLevelId([super supportedCodecs]);
}
@end
@implementation VideoEncoderFactorySimulcast
- (NSArray<RTC_OBJC_TYPE(RTCVideoCodecInfo)*>*)supportedCodecs {
  return motifyH264ProfileLevelId([super supportedCodecs]);
}
@end

#pragma mark - JSON 桥工具

struct WebrtcJsonBridge {
  // NSDictionary/NSArray/NSString/NSNumber/NSNull 可直接序列化; NSData → base64
};
static NSData* __nullable WebrtcJsonData(NSDictionary* __nonnull dict);
static id __nonnull WebrtcJsonSanitize(id __nullable obj);

static NSData* WebrtcJsonData(NSDictionary* dict) {
  if (!dict) return nil;
  return [NSJSONSerialization dataWithJSONObject:WebrtcJsonSanitize(dict)
                                         options:0
                                           error:nil];
}

// NSData → base64 字符串, 其余原样。递归处理嵌套 dict/array。
static id WebrtcJsonSanitize(id obj) {
  if (!obj) return [NSNull null];
  if ([obj isKindOfClass:[NSData class]]) {
    return [(NSData*)obj base64EncodedStringWithOptions:0];
  }
  if ([obj isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary* out = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
    for (id k in obj) {
      out[k] = WebrtcJsonSanitize(obj[k]);
    }
    return out;
  }
  if ([obj isKindOfClass:[NSArray class]]) {
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:[obj count]];
    for (id item in obj) {
      [out addObject:WebrtcJsonSanitize(item)];
    }
    return out;
  }
  return obj;
}

static NSDictionary* __nullable WebrtcParseJson(const char* json) {
  if (!json || json[0] == '\0') return nil;
  NSData* data = [NSData dataWithBytes:json length:strlen(json)];
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if ([obj isKindOfClass:[NSDictionary class]]) return obj;
  return nil;
}

static NSString* __nullable WebrtcCString(const char* s) {
  return (s && s[0]) ? [NSString stringWithUTF8String:s] : nil;
}

// malloc 字符串, 由 webrtc_free_string 释放
static char* WebrtcMallocString(NSString* __nullable s) {
  if (!s) return NULL;
  const char* utf8 = s.UTF8String;
  if (!utf8) return NULL;
  char* out = (char*)malloc(strlen(utf8) + 1);
  if (out) strcpy(out, utf8);
  return out;
}

#pragma mark - WebrtcEventCallback / WebrtcError / WebrtcResultMake

@implementation WebrtcEventCallback

- (void)post:(NSDictionary*)event {
  [self post:event binary:nil];
}

- (void)post:(NSDictionary*)event binary:(NSData*)binary {
  // 二进制消息: JSON 的 "data" 置空串, 原始字节从 binary 指针直传
  id sanitized = WebrtcJsonSanitize(event);
  if (binary) {
    // 把 "data" 字段置空——数据走 binary 参数
    if ([sanitized isKindOfClass:[NSMutableDictionary class]]) {
      ((NSMutableDictionary*)sanitized)[@"data"] = @"";
    }
  }
  NSData* jsonData = [NSJSONSerialization dataWithJSONObject:sanitized options:0 error:nil];
  if (!jsonData) return;
  NSString* json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
  if (!json) return;
  if (!self.cb) return;
  webrtc_event_cb cb = self.cb;
  void* ud = self.userData;
  const char* cstr = [json UTF8String];
  char* copy = (char*)malloc(strlen(cstr) + 1);
  if (copy) strcpy(copy, cstr);
  // 二进制也 malloc 拷贝: NativeCallable 异步编组时 NSData 可能已释放;
  // Dart 侧对 binary 也用 webrtc_free_string(free) 释放, 必须是真的 malloc。
  NSData* binData = binary;
  uint8_t* binCopy = NULL;
  if (binData && binData.length > 0) {
    binCopy = (uint8_t*)malloc(binData.length);
    if (binCopy) memcpy(binCopy, binData.bytes, binData.length);
  }
  // 直接调 cb(不走 dispatch_get_main_queue): Dart CLI 进程没有主 RunLoop,
  // main queue 的 block 永不执行, 事件会全部丢失。NativeCallable.listener 自带
  // 跨线程编组, 在 webrtc 线程直接调即可送达 isolate。
  // copy/binCopy 所有权转交 Dart 侧, 这里不能 free。
  cb(ud, copy, binCopy, binData ? (int)binData.length : 0);
}

- (void)postString:(NSString*)json {
  if (!self.cb) return;
  webrtc_event_cb cb = self.cb;
  void* ud = self.userData;
  const char* cstr = [json UTF8String];
  char* copy = (char*)malloc(strlen(cstr) + 1);
  if (copy) strcpy(copy, cstr);
  // 同 post:binary:, 直接调 cb, 不走 main queue(Dart CLI 无主 RunLoop)
  cb(ud, copy, NULL, 0);
}

@end

@implementation WebrtcError
+ (instancetype)errorWithCode:(NSString*)code message:(NSString*)message details:(id)details {
  WebrtcError* e = [WebrtcError new];
  e.code = code;
  e.message = message;
  e.details = details;
  return e;
}
@end

static void WebrtcResultFire(webrtc_result_cb cb, void* ud, int err, id result) {
  NSString* json = nil;
  if (result && [result isKindOfClass:[NSDictionary class]]) {
    json = [[NSString alloc] initWithData:WebrtcJsonData(result) encoding:NSUTF8StringEncoding];
  }
  const char* cjson = json ? [json UTF8String] : NULL;
  char* copy = cjson ? (char*)malloc(strlen(cjson) + 1) : NULL;
  if (copy) strcpy(copy, cjson);
  // copy 所有权转交 Dart 侧(异步编组, Dart 读完后 webrtc_free_string 释放)。不能 free。
  cb(ud, err, copy);
}

WebrtcResult WebrtcResultMake(void* userData, webrtc_result_cb cb) {
  __block webrtc_result_cb fcb = cb;
  __block void* fud = userData;
  return ^(id result) {
    if (fcb == NULL) return;
    if ([result isKindOfClass:[WebrtcError class]]) {
      WebrtcError* e = result;
      NSString* msg = e.message ? e.message : e.code ? e.code : @"error";
      // 用 C 字符串错误码回调失败(err!=0)
      const char* m = [msg UTF8String];
      char* copy = (char*)malloc(strlen(m) + 1);
      if (copy) strcpy(copy, m);
      fcb(fud, 1, copy);  // 所有权转交 Dart 侧, 不能 free
      return;
    }
    if (result == nil || result == [NSNull null]) {
      fcb(fud, 0, NULL);
      return;
    }
    WebrtcResultFire(fcb, fud, 0, result);
  };
}

#pragma mark - WebrtcPlugin 实现

@implementation WebrtcPlugin {
  RTCCallbackLogger* loggerCallback;
}

static WebrtcPlugin* sharedInstance_;

+ (WebrtcPlugin*)sharedInstance {
  @synchronized(self) {
    if (!sharedInstance_) {
      sharedInstance_ = [[WebrtcPlugin alloc] init];
      NSLog(@"[DBG-sharedInstance] 首次创建 WebrtcPlugin=%p", sharedInstance_);
    }
    return sharedInstance_;
  }
}

- (instancetype)init {
  self = [super init];
  if (self) {
    self.peerConnections = [NSMutableDictionary new];
    self.localStreams = [NSMutableDictionary new];
    self.localTracks = [NSMutableDictionary new];
    self.videoCapturerStopHandlers = [NSMutableDictionary new];
    self.frameCryptors = [NSMutableDictionary new];
    self.keyProviders = [NSMutableDictionary new];
    self.audioManager = AudioManager.sharedInstance;
  }
  return self;
}

- (void)ensureAudioSession {
  // macOS 无 AVAudioSession; darwin 的 ensureAudioSession 为 iOS 专用, 此处空实现
}

#pragma mark - RTCAudioDeviceModuleDelegate (新框架 9 个必选方法, 全量实现避免 unrecognized selector)
// 本 xcframework 是 macOS 26.2 SDK 构建, RTCAudioDeviceModuleDelegate 协议已扩展。
// darwin 只实现 audioDeviceModuleDidUpdateDevices:(旧协议), 这里补齐全部必选方法。
// 引擎生命周期钩子对 webrtc-cli 无自定义需求, 统一返回 0(成功)。

- (void)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
    didReceiveSpeechActivityEvent:(RTCSpeechActivityEvent)speechActivityEvent {
  // 无消费方, 忽略
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
               didCreateEngine:(AVAudioEngine*)engine {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
              willEnableEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
               willStartEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
                 didStopEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
              didDisableEngine:(AVAudioEngine*)engine
              isPlayoutEnabled:(BOOL)isPlayoutEnabled
            isRecordingEnabled:(BOOL)isRecordingEnabled {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
             willReleaseEngine:(AVAudioEngine*)engine {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
                        engine:(AVAudioEngine*)engine
      configureInputFromSource:(AVAudioNode*)source
                 toDestination:(AVAudioNode*)destination
                    withFormat:(AVAudioFormat*)format
                       context:(NSDictionary*)context {
  return 0;
}

- (NSInteger)audioDeviceModule:(RTCAudioDeviceModule*)audioDeviceModule
                        engine:(AVAudioEngine*)engine
     configureOutputFromSource:(AVAudioNode*)source
                 toDestination:(AVAudioNode*)destination
                    withFormat:(AVAudioFormat*)format
                       context:(NSDictionary*)context {
  return 0;
}

- (void)audioDeviceModuleDidUpdateDevices:(RTCAudioDeviceModule*)audioDeviceModule {
  [self postFactoryEvent:@{@"event" : @"onDeviceChange"}];
}

- (void)postFactoryEvent:(NSDictionary*)event {
  if (!self.factoryEventCb) return;
  WebrtcEventCallback* cb = [WebrtcEventCallback new];
  cb.cb = self.factoryEventCb;
  cb.userData = self.factoryEventUd;
  [cb post:event];
}

- (void)initializeFactory {
  [self initializeFactoryWithNetworkIgnoreMask:nil
                        bypassVoiceProcessing:NO
                                     severity:nil];
}

// 照抄 darwin initLoggerCallback:severity:, 事件改走 factory 级 C 回调(onLogData)
- (void)initLoggerCallback:(RTCLoggingSeverity)severity {
  if (loggerCallback == nil) {
    loggerCallback = [RTCCallbackLogger new];
    [loggerCallback start:^(NSString* logMessage) {
      [self postFactoryEvent:@{
        @"event" : @"onLogData",
        @"data" : logMessage
      }];
    }];
  }
  loggerCallback.severity = severity;
}

// 照抄 darwin str2LogSeverity:, 未知/nil 默认 RTCLoggingSeverityNone
- (RTCLoggingSeverity)str2LogSeverity:(NSString*)str {
  if ([@"verbose" isEqualToString:str]) {
    return RTCLoggingSeverityVerbose;
  } else if ([@"info" isEqualToString:str]) {
    return RTCLoggingSeverityInfo;
  } else if ([@"warning" isEqualToString:str]) {
    return RTCLoggingSeverityWarning;
  } else if ([@"error" isEqualToString:str]) {
    return RTCLoggingSeverityError;
  } else if ([@"none" isEqualToString:str]) {
    return RTCLoggingSeverityNone;
  }
  return RTCLoggingSeverityNone;
}

- (void)initializeFactoryWithNetworkIgnoreMask:(NSArray*)networkIgnoreMask
                         bypassVoiceProcessing:(BOOL)bypassVoiceProcessing
                                      severity:(NSString*)severityStr {
  if (!_peerConnectionFactory) {
    // 对齐 darwin initWithChannel: 的 RTCInitFieldTrialDictionary(网络路径行为)
    NSDictionary* fieldTrials = @{kRTCFieldTrialUseNWPathMonitor : kRTCFieldTrialEnabledValue};
    RTCInitFieldTrialDictionary(fieldTrials);

    // 对齐 darwin initialize:severity: 的日志回调(onLogData 走 factory 事件回调)
    [self initLoggerCallback:[self str2LogSeverity:severityStr]];

    VideoDecoderFactory* decoderFactory = [[VideoDecoderFactory alloc] init];
    VideoEncoderFactory* encoderFactory = [[VideoEncoderFactory alloc] init];
    VideoEncoderFactorySimulcast* simulcastFactory =
        [[VideoEncoderFactorySimulcast alloc] initWithPrimary:encoderFactory
                                                     fallback:encoderFactory];

    _peerConnectionFactory =
        [[RTCPeerConnectionFactory alloc] initWithAudioDeviceModuleType:RTCAudioDeviceModuleTypeAudioEngine
                                                  bypassVoiceProcessing:bypassVoiceProcessing
                                                         encoderFactory:simulcastFactory
                                                         decoderFactory:decoderFactory
                                                  audioProcessingModule:_audioManager.audioProcessingModule];

    RTCPeerConnectionFactoryOptions* options = [[RTCPeerConnectionFactoryOptions alloc] init];
    for (NSString* adapter in networkIgnoreMask) {
      if ([@"adapterTypeEthernet" isEqualToString:adapter]) {
        options.ignoreEthernetNetworkAdapter = YES;
      } else if ([@"adapterTypeWifi" isEqualToString:adapter]) {
        options.ignoreWiFiNetworkAdapter = YES;
      } else if ([@"adapterTypeCellular" isEqualToString:adapter]) {
        options.ignoreCellularNetworkAdapter = YES;
      } else if ([@"adapterTypeVpn" isEqualToString:adapter]) {
        options.ignoreVPNNetworkAdapter = YES;
      } else if ([@"adapterTypeLoopback" isEqualToString:adapter]) {
        options.ignoreLoopbackNetworkAdapter = YES;
      } else if ([@"adapterTypeAny" isEqualToString:adapter]) {
        options.ignoreEthernetNetworkAdapter = YES;
        options.ignoreWiFiNetworkAdapter = YES;
        options.ignoreCellularNetworkAdapter = YES;
        options.ignoreVPNNetworkAdapter = YES;
        options.ignoreLoopbackNetworkAdapter = YES;
      }
    }
    [_peerConnectionFactory setOptions:options];

    // 对齐 darwin: 观察音频设备模块事件(设备热插拔 onDeviceChange)
    _peerConnectionFactory.audioDeviceModule.observer = self;

    _emptyPcFactory = [_peerConnectionFactory copySharedField];
    [_emptyPcFactory setEmptyAdm];
    [_emptyPcFactory initWithAudioDeviceModuleType:RTCAudioDeviceModuleTypeAudioEngine
                             bypassVoiceProcessing:YES
                                    encoderFactory:simulcastFactory
                                    decoderFactory:decoderFactory
                             audioProcessingModule:_audioManager.audioProcessingModule];
    [_emptyPcFactory setOptions:options];
  }
}

#pragma mark - 与 darwin 同名同签名的业务方法(照抄)

- (RTCMediaStream*)streamForId:(NSString*)streamId peerConnectionId:(NSString*)peerConnectionId {
  RTCMediaStream* stream = nil;
  if (peerConnectionId.length > 0) {
    RTCPeerConnection* peerConnection = [_peerConnections objectForKey:peerConnectionId];
    stream = peerConnection.remoteStreams[streamId];
  } else {
    for (RTCPeerConnection* peerConnection in _peerConnections.allValues) {
      stream = peerConnection.remoteStreams[streamId];
      if (stream) break;
    }
  }
  if (!stream) {
    stream = _localStreams[streamId];
  }
  return stream;
}

- (RTCMediaStreamTrack*)trackForId:(NSString*)trackId peerConnectionId:(NSString*)peerConnectionId {
  id<LocalTrack> track = _localTracks[trackId];
  RTCMediaStreamTrack* mediaStreamTrack = nil;
  if (!track) {
    for (NSString* currentId in _peerConnections.allKeys) {
      if (peerConnectionId && [currentId isEqualToString:peerConnectionId] == false) continue;
      RTCPeerConnection* peerConnection = _peerConnections[currentId];
      mediaStreamTrack = peerConnection.remoteTracks[trackId];
      if (!mediaStreamTrack) {
        for (RTCRtpTransceiver* transceiver in peerConnection.transceivers) {
          if (transceiver.receiver.track != nil &&
              [transceiver.receiver.track.trackId isEqual:trackId]) {
            mediaStreamTrack = transceiver.receiver.track;
            break;
          }
        }
      }
      if (mediaStreamTrack) break;
    }
  } else {
    mediaStreamTrack = [track track];
  }
  return mediaStreamTrack;
}

- (RTCRtpSender*)getRtpSenderById:(RTCPeerConnection*)peerConnection Id:(NSString*)Id {
  for (RTCRtpSender* sender in peerConnection.senders) {
    if ([sender.senderId isEqualToString:Id]) return sender;
  }
  return nil;
}

- (RTCRtpReceiver*)getRtpReceiverById:(RTCPeerConnection*)peerConnection Id:(NSString*)Id {
  for (RTCRtpReceiver* receiver in peerConnection.receivers) {
    if ([receiver.receiverId isEqualToString:Id]) return receiver;
  }
  return nil;
}

- (RTCRtpTransceiver*)getRtpTransceiverById:(RTCPeerConnection*)peerConnection Id:(NSString*)Id {
  for (RTCRtpTransceiver* transceiver in peerConnection.transceivers) {
    NSString* mid = transceiver.mid ? transceiver.mid : @"";
    if ([mid isEqualToString:Id]) return transceiver;
  }
  return nil;
}

- (RTCIceServer*)RTCIceServer:(id)json {
  if (!json) return nil;
  if (![json isKindOfClass:[NSDictionary class]]) return nil;
  NSArray<NSString*>* urls;
  if ([json[@"url"] isKindOfClass:[NSString class]]) {
    urls = @[ json[@"url"] ];
  } else if ([json[@"urls"] isKindOfClass:[NSString class]]) {
    urls = @[ json[@"urls"] ];
  } else {
    urls = (NSArray*)json[@"urls"];
  }
  if (json[@"username"] != nil || json[@"credential"] != nil) {
    return [[RTCIceServer alloc] initWithURLStrings:urls
                                           username:json[@"username"]
                                         credential:json[@"credential"]];
  }
  return [[RTCIceServer alloc] initWithURLStrings:urls];
}

- (RTCConfiguration*)RTCConfiguration:(id)json {
  RTCConfiguration* config = [[RTCConfiguration alloc] init];
  if (!json || ![json isKindOfClass:[NSDictionary class]]) return config;

  if (json[@"audioJitterBufferMaxPackets"] != nil &&
      [json[@"audioJitterBufferMaxPackets"] isKindOfClass:[NSNumber class]]) {
    config.audioJitterBufferMaxPackets = [json[@"audioJitterBufferMaxPackets"] intValue];
  }
  if (json[@"bundlePolicy"] != nil && [json[@"bundlePolicy"] isKindOfClass:[NSString class]]) {
    NSString* bundlePolicy = json[@"bundlePolicy"];
    if ([bundlePolicy isEqualToString:@"balanced"]) {
      config.bundlePolicy = RTCBundlePolicyBalanced;
    } else if ([bundlePolicy isEqualToString:@"max-compat"]) {
      config.bundlePolicy = RTCBundlePolicyMaxCompat;
    } else if ([bundlePolicy isEqualToString:@"max-bundle"]) {
      config.bundlePolicy = RTCBundlePolicyMaxBundle;
    }
  }
  if (json[@"iceBackupCandidatePairPingInterval"] != nil &&
      [json[@"iceBackupCandidatePairPingInterval"] isKindOfClass:[NSNumber class]]) {
    config.iceBackupCandidatePairPingInterval =
        [json[@"iceBackupCandidatePairPingInterval"] intValue];
  }
  if (json[@"iceConnectionReceivingTimeout"] != nil &&
      [json[@"iceConnectionReceivingTimeout"] isKindOfClass:[NSNumber class]]) {
    config.iceConnectionReceivingTimeout = [json[@"iceConnectionReceivingTimeout"] intValue];
  }
  if (json[@"iceServers"] != nil && [json[@"iceServers"] isKindOfClass:[NSArray class]]) {
    NSMutableArray<RTCIceServer*>* iceServers = [NSMutableArray new];
    for (id server in json[@"iceServers"]) {
      RTCIceServer* convert = [self RTCIceServer:server];
      if (convert != nil) [iceServers addObject:convert];
    }
    config.iceServers = iceServers;
  }
  if (json[@"iceTransportPolicy"] != nil &&
      [json[@"iceTransportPolicy"] isKindOfClass:[NSString class]]) {
    NSString* p = json[@"iceTransportPolicy"];
    if ([p isEqualToString:@"all"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyAll;
    } else if ([p isEqualToString:@"none"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyNone;
    } else if ([p isEqualToString:@"nohost"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyNoHost;
    } else if ([p isEqualToString:@"relay"]) {
      config.iceTransportPolicy = RTCIceTransportPolicyRelay;
    }
  }
  if (json[@"rtcpMuxPolicy"] != nil && [json[@"rtcpMuxPolicy"] isKindOfClass:[NSString class]]) {
    NSString* p = json[@"rtcpMuxPolicy"];
    if ([p isEqualToString:@"negotiate"]) {
      config.rtcpMuxPolicy = RTCRtcpMuxPolicyNegotiate;
    } else if ([p isEqualToString:@"require"]) {
      config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    }
  }
  if (json[@"sdpSemantics"] != nil && [json[@"sdpSemantics"] isKindOfClass:[NSString class]]) {
    NSString* s = json[@"sdpSemantics"];
    if ([s isEqualToString:@"plan-b"]) {
      config.sdpSemantics = RTCSdpSemanticsPlanB;
    } else if ([s isEqualToString:@"unified-plan"]) {
      config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    }
  }
  if (json[@"maxIPv6Networks"] != nil && [json[@"maxIPv6Networks"] isKindOfClass:[NSNumber class]]) {
    config.maxIPv6Networks = [json[@"maxIPv6Networks"] intValue];
  }
  if (json[@"tcpCandidatePolicy"] != nil &&
      [json[@"tcpCandidatePolicy"] isKindOfClass:[NSString class]]) {
    NSString* p = json[@"tcpCandidatePolicy"];
    if ([p isEqualToString:@"enabled"]) {
      config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled;
    } else if ([p isEqualToString:@"disabled"]) {
      config.tcpCandidatePolicy = RTCTcpCandidatePolicyDisabled;
    }
  }
  if (json[@"candidateNetworkPolicy"] != nil &&
      [json[@"candidateNetworkPolicy"] isKindOfClass:[NSString class]]) {
    NSString* p = json[@"candidateNetworkPolicy"];
    if ([p isEqualToString:@"all"]) {
      config.candidateNetworkPolicy = RTCCandidateNetworkPolicyAll;
    } else if ([p isEqualToString:@"low_cost"]) {
      config.candidateNetworkPolicy = RTCCandidateNetworkPolicyLowCost;
    }
  }
  if (json[@"keyType"] != nil && [json[@"keyType"] isKindOfClass:[NSString class]]) {
    NSString* p = json[@"keyType"];
    if ([p isEqualToString:@"RSA"]) {
      config.keyType = RTCEncryptionKeyTypeRSA;
    } else if ([p isEqualToString:@"ECDSA"]) {
      config.keyType = RTCEncryptionKeyTypeECDSA;
    }
  }
  if (json[@"continualGatheringPolicy"] != nil &&
      [json[@"continualGatheringPolicy"] isKindOfClass:[NSString class]]) {
    NSString* p = json[@"continualGatheringPolicy"];
    if ([p isEqualToString:@"gather_once"]) {
      config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherOnce;
    } else if ([p isEqualToString:@"gather_continually"]) {
      config.continualGatheringPolicy = RTCContinualGatheringPolicyGatherContinually;
    }
  }
  if (json[@"audioJitterBufferFastAccelerate"] != nil &&
      [json[@"audioJitterBufferFastAccelerate"] isKindOfClass:[NSNumber class]]) {
    config.audioJitterBufferFastAccelerate =
        [json[@"audioJitterBufferFastAccelerate"] boolValue];
  }
  if (json[@"pruneTurnPorts"] != nil && [json[@"pruneTurnPorts"] isKindOfClass:[NSNumber class]]) {
    config.shouldPruneTurnPorts = [json[@"pruneTurnPorts"] boolValue];
  }
  if (json[@"presumeWritableWhenFullyRelayed"] != nil &&
      [json[@"presumeWritableWhenFullyRelayed"] isKindOfClass:[NSNumber class]]) {
    config.shouldPresumeWritableWhenFullyRelayed =
        [json[@"presumeWritableWhenFullyRelayed"] boolValue];
  }
  if (json[@"cryptoOptions"] != nil &&
      [json[@"cryptoOptions"] isKindOfClass:[NSDictionary class]]) {
    id options = json[@"cryptoOptions"];
    BOOL srtpEnableGcmCryptoSuites = NO;
    BOOL sframeRequireFrameEncryption = NO;
    BOOL srtpEnableEncryptedRtpHeaderExtensions = NO;
    BOOL srtpEnableAes128Sha1_32CryptoCipher = NO;
    if ([options[@"enableGcmCryptoSuites"] isKindOfClass:[NSNumber class]])
      srtpEnableGcmCryptoSuites = [options[@"enableGcmCryptoSuites"] boolValue];
    if ([options[@"requireFrameEncryption"] isKindOfClass:[NSNumber class]])
      sframeRequireFrameEncryption = [options[@"requireFrameEncryption"] boolValue];
    if ([options[@"enableEncryptedRtpHeaderExtensions"] isKindOfClass:[NSNumber class]])
      srtpEnableEncryptedRtpHeaderExtensions =
          [options[@"enableEncryptedRtpHeaderExtensions"] boolValue];
    if ([options[@"enableAes128Sha1_32CryptoCipher"] isKindOfClass:[NSNumber class]])
      srtpEnableAes128Sha1_32CryptoCipher =
          [options[@"enableAes128Sha1_32CryptoCipher"] boolValue];
    config.cryptoOptions = [[RTCCryptoOptions alloc]
             initWithSrtpEnableGcmCryptoSuites:srtpEnableGcmCryptoSuites
           srtpEnableAes128Sha1_32CryptoCipher:srtpEnableAes128Sha1_32CryptoCipher
        srtpEnableEncryptedRtpHeaderExtensions:srtpEnableEncryptedRtpHeaderExtensions
                  sframeRequireFrameEncryption:sframeRequireFrameEncryption];
  }
  return config;
}

- (NSString*)streamTrackStateToString:(RTCMediaStreamTrackState)state {
  switch (state) {
    case RTCMediaStreamTrackStateLive:
      return @"live";
    case RTCMediaStreamTrackStateEnded:
      return @"ended";
  }
  return @"";
}

- (NSDictionary*)mediaStreamToMap:(RTCMediaStream*)stream ownerTag:(NSString*)ownerTag {
  NSMutableArray* audioTracks = [NSMutableArray array];
  NSMutableArray* videoTracks = [NSMutableArray array];
  for (RTCMediaStreamTrack* track in stream.audioTracks) {
    [audioTracks addObject:[self mediaTrackToMap:track]];
  }
  for (RTCMediaStreamTrack* track in stream.videoTracks) {
    [videoTracks addObject:[self mediaTrackToMap:track]];
  }
  return @{
    @"streamId" : stream.streamId,
    @"ownerTag" : ownerTag,
    @"audioTracks" : audioTracks,
    @"videoTracks" : videoTracks,
  };
}

- (NSDictionary*)mediaTrackToMap:(RTCMediaStreamTrack*)track {
  if (track == nil) return @{};
  return @{
    @"enabled" : @(track.isEnabled),
    @"id" : track.trackId,
    @"kind" : track.kind,
    @"label" : track.trackId,
    @"readyState" : [self streamTrackStateToString:track.readyState],
    @"remote" : @(YES)
  };
}

- (NSDictionary*)dtmfSenderToMap:(id<RTCDtmfSender>)dtmf Id:(NSString*)Id {
  return @{
    @"dtmfSenderId" : Id,
    @"interToneGap" : @(dtmf.interToneGap / 1000.0),
    @"duration" : @(dtmf.duration / 1000.0),
  };
}

- (NSDictionary*)rtpParametersToMap:(RTCRtpParameters*)parameters {
  NSDictionary* rtcp = @{
    @"cname" : parameters.rtcp.cname,
    @"reducedSize" : @(parameters.rtcp.isReducedSize),
  };
  NSMutableArray* headerExtensions = [NSMutableArray array];
  for (RTCRtpHeaderExtension* headerExtension in parameters.headerExtensions) {
    [headerExtensions addObject:@{
      @"uri" : headerExtension.uri,
      @"encrypted" : @(headerExtension.encrypted),
      @"id" : @(headerExtension.id),
    }];
  }
  NSMutableArray* encodings = [NSMutableArray array];
  for (RTCRtpEncodingParameters* encoding in parameters.encodings) {
    NSMutableDictionary* obj = [@{@"active" : @(encoding.isActive)} mutableCopy];
    if (encoding.rid != nil) [obj setObject:encoding.rid forKey:@"rid"];
    if (encoding.minBitrateBps != nil) [obj setObject:encoding.minBitrateBps forKey:@"minBitrate"];
    if (encoding.maxBitrateBps != nil) [obj setObject:encoding.maxBitrateBps forKey:@"maxBitrate"];
    if (encoding.maxFramerate != nil) [obj setObject:encoding.maxFramerate forKey:@"maxFramerate"];
    if (encoding.numTemporalLayers != nil)
      [obj setObject:encoding.numTemporalLayers forKey:@"numTemporalLayers"];
    if (encoding.scaleResolutionDownBy != nil)
      [obj setObject:encoding.scaleResolutionDownBy forKey:@"scaleResolutionDownBy"];
    if (encoding.ssrc != nil) [obj setObject:encoding.ssrc forKey:@"ssrc"];
    [encodings addObject:obj];
  }
  NSMutableArray* codecs = [NSMutableArray array];
  for (RTCRtpCodecParameters* codec in parameters.codecs) {
    [codecs addObject:@{
      @"name" : codec.name,
      @"payloadType" : @(codec.payloadType),
      @"clockRate" : codec.clockRate,
      @"numChannels" : codec.numChannels ? codec.numChannels : @(1),
      @"parameters" : codec.parameters,
      @"kind" : codec.kind
    }];
  }
  NSString* degradationPreference = @"balanced";
  if (parameters.degradationPreference != nil) {
    if ([parameters.degradationPreference intValue] == RTCDegradationPreferenceMaintainFramerate) {
      degradationPreference = @"maintain-framerate";
    } else if ([parameters.degradationPreference intValue] ==
               RTCDegradationPreferenceMaintainResolution) {
      degradationPreference = @"maintain-resolution";
    } else if ([parameters.degradationPreference intValue] == RTCDegradationPreferenceBalanced) {
      degradationPreference = @"balanced";
    } else if ([parameters.degradationPreference intValue] == RTCDegradationPreferenceDisabled) {
      degradationPreference = @"disabled";
    }
  }
  return @{
    @"transactionId" : parameters.transactionId,
    @"rtcp" : rtcp,
    @"headerExtensions" : headerExtensions,
    @"encodings" : encodings,
    @"codecs" : codecs,
    @"degradationPreference" : degradationPreference,
  };
}

- (RTCRtpParameters*)updateRtpParameters:(RTCRtpParameters*)parameters
                                    with:(NSDictionary*)newParameters {
  NSArray<RTCRtpEncodingParameters*>* currentEncodings = parameters.encodings;
  NSArray* newEncodings = [newParameters objectForKey:@"encodings"];
  NSString* degradationPreference = [newParameters objectForKey:@"degradationPreference"];
  if (degradationPreference != nil) {
    if ([degradationPreference isEqualToString:@"maintain-framerate"]) {
      parameters.degradationPreference =
          [NSNumber numberWithInt:RTCDegradationPreferenceMaintainFramerate];
    } else if ([degradationPreference isEqualToString:@"maintain-resolution"]) {
      parameters.degradationPreference =
          [NSNumber numberWithInt:RTCDegradationPreferenceMaintainResolution];
    } else if ([degradationPreference isEqualToString:@"balanced"]) {
      parameters.degradationPreference = [NSNumber numberWithInt:RTCDegradationPreferenceBalanced];
    } else if ([degradationPreference isEqualToString:@"disabled"]) {
      parameters.degradationPreference = [NSNumber numberWithInt:RTCDegradationPreferenceDisabled];
    }
  }
  for (int i = 0; i < [newEncodings count]; i++) {
    RTCRtpEncodingParameters* currentParams = nil;
    NSDictionary* newParams = [newEncodings objectAtIndex:i];
    NSString* rid = [newParams objectForKey:@"rid"];
    if ([rid isKindOfClass:[NSString class]] && [rid length] != 0) {
      NSUInteger result =
          [currentEncodings indexOfObjectPassingTest:^BOOL(RTCRtpEncodingParameters* _Nonnull obj,
                                                           NSUInteger idx,
                                                           BOOL* _Nonnull stop) {
            return (*stop = ([rid isEqualToString:obj.rid]));
          }];
      if (result != NSNotFound) currentParams = [currentEncodings objectAtIndex:result];
    }
    if (currentParams == nil && i < [currentEncodings count]) {
      currentParams = [currentEncodings objectAtIndex:i];
    }
    if (currentParams != nil) {
      NSNumber* active = [newParams objectForKey:@"active"];
      if (active != nil) currentParams.isActive = [active boolValue];
      NSNumber* maxBitrate = [newParams objectForKey:@"maxBitrate"];
      if (maxBitrate != nil) currentParams.maxBitrateBps = maxBitrate;
      NSNumber* minBitrate = [newParams objectForKey:@"minBitrate"];
      if (minBitrate != nil) currentParams.minBitrateBps = minBitrate;
      NSNumber* maxFramerate = [newParams objectForKey:@"maxFramerate"];
      if (maxFramerate != nil) currentParams.maxFramerate = maxFramerate;
      NSNumber* numTemporalLayers = [newParams objectForKey:@"numTemporalLayers"];
      if (numTemporalLayers != nil) currentParams.numTemporalLayers = numTemporalLayers;
      NSNumber* scaleResolutionDownBy = [newParams objectForKey:@"scaleResolutionDownBy"];
      if (scaleResolutionDownBy != nil) currentParams.scaleResolutionDownBy = scaleResolutionDownBy;
    }
  }
  return parameters;
}

- (NSDictionary*)rtpSenderToMap:(RTCRtpSender*)sender {
  return @{
    @"senderId" : sender.senderId,
    @"ownsTrack" : @(YES),
    @"rtpParameters" : [self rtpParametersToMap:sender.parameters],
    @"track" : [self mediaTrackToMap:sender.track],
    @"dtmfSender" : [self dtmfSenderToMap:sender.dtmfSender Id:sender.senderId]
  };
}

- (NSDictionary*)receiverToMap:(RTCRtpReceiver*)receiver {
  return @{
    @"receiverId" : receiver.receiverId,
    @"rtpParameters" : [self rtpParametersToMap:receiver.parameters],
    @"track" : [self mediaTrackToMap:receiver.track],
  };
}

- (NSString*)transceiverDirectionString:(RTCRtpTransceiverDirection)direction {
  switch (direction) {
    case RTCRtpTransceiverDirectionSendRecv:
      return @"sendrecv";
    case RTCRtpTransceiverDirectionSendOnly:
      return @"sendonly";
    case RTCRtpTransceiverDirectionRecvOnly:
      return @"recvonly";
    case RTCRtpTransceiverDirectionInactive:
      return @"inactive";
    case RTCRtpTransceiverDirectionStopped:
      return @"stopped";
  }
  return nil;
}

- (NSDictionary*)transceiverToMap:(RTCRtpTransceiver*)transceiver {
  NSString* mid = transceiver.mid ? transceiver.mid : @"";
  return @{
    @"transceiverId" : mid,
    @"mid" : mid,
    @"direction" : [self transceiverDirectionString:transceiver.direction],
    @"sender" : [self rtpSenderToMap:transceiver.sender],
    @"receiver" : [self receiverToMap:transceiver.receiver]
  };
}

/* ---- 以下四个 helper 照抄 darwin FlutterWebRTCPlugin.m 2320-2419,
 *      用于 addTransceiver(init/sendEncodings/direction/mediaType) ---- */

- (RTCRtpEncodingParameters*)mapToEncoding:(NSDictionary*)map {
  RTCRtpEncodingParameters* encoding = [[RTCRtpEncodingParameters alloc] init];
  encoding.isActive = YES;
  encoding.scaleResolutionDownBy = [NSNumber numberWithDouble:1.0];
  encoding.numTemporalLayers = [NSNumber numberWithInt:1];
#if TARGET_OS_IPHONE
  encoding.networkPriority = RTCPriorityLow;
  encoding.bitratePriority = 1.0;
#endif
  [encoding setRid:map[@"rid"]];

  if (map[@"active"] != nil) {
    [encoding setIsActive:((NSNumber*)map[@"active"]).boolValue];
  }

  if (map[@"minBitrate"] != nil) {
    [encoding setMinBitrateBps:(NSNumber*)map[@"minBitrate"]];
  }

  if (map[@"maxBitrate"] != nil) {
    [encoding setMaxBitrateBps:(NSNumber*)map[@"maxBitrate"]];
  }

  if (map[@"maxFramerate"] != nil) {
    [encoding setMaxFramerate:(NSNumber*)map[@"maxFramerate"]];
  }

  if (map[@"numTemporalLayers"] != nil) {
    [encoding setNumTemporalLayers:(NSNumber*)map[@"numTemporalLayers"]];
  }

  if (map[@"scaleResolutionDownBy"] != nil) {
    [encoding setScaleResolutionDownBy:(NSNumber*)map[@"scaleResolutionDownBy"]];
  }

  if (map[@"scalabilityMode"] != nil) {
    [encoding setScalabilityMode:(NSString*)map[@"scalabilityMode"]];
  }

  return encoding;
}

- (RTCRtpTransceiverInit*)mapToTransceiverInit:(NSDictionary*)map {
  NSArray<NSString*>* streamIds = map[@"streamIds"];
  NSArray<NSDictionary*>* encodingsParams = map[@"sendEncodings"];
  NSString* direction = map[@"direction"];

  RTCRtpTransceiverInit* init = [RTCRtpTransceiverInit alloc];

  if (direction != nil) {
    init.direction = [self stringToTransceiverDirection:direction];
  }

  if (streamIds != nil) {
    init.streamIds = streamIds;
  }

  if (encodingsParams != nil) {
    NSMutableArray<RTCRtpEncodingParameters*>* sendEncodings = [[NSMutableArray alloc] init];
    for (NSDictionary* map in encodingsParams) {
      [sendEncodings addObject:[self mapToEncoding:map]];
    }
    [init setSendEncodings:sendEncodings];
  }
  return init;
}

- (RTCRtpMediaType)stringToRtpMediaType:(NSString*)type {
  if ([type isEqualToString:@"audio"]) {
    return RTCRtpMediaTypeAudio;
  } else if ([type isEqualToString:@"video"]) {
    return RTCRtpMediaTypeVideo;
  } else if ([type isEqualToString:@"data"]) {
    return RTCRtpMediaTypeData;
  }
  return RTCRtpMediaTypeAudio;
}

- (RTCRtpTransceiverDirection)stringToTransceiverDirection:(NSString*)type {
  if ([type isEqualToString:@"sendrecv"]) {
    return RTCRtpTransceiverDirectionSendRecv;
  } else if ([type isEqualToString:@"sendonly"]) {
    return RTCRtpTransceiverDirectionSendOnly;
  } else if ([type isEqualToString:@"recvonly"]) {
    return RTCRtpTransceiverDirectionRecvOnly;
  } else if ([type isEqualToString:@"inactive"]) {
    return RTCRtpTransceiverDirectionInactive;
  }
  return RTCRtpTransceiverDirectionInactive;
}

#pragma mark - createPeerConnection(照抄 darwin handleMethodCall)

- (void)createPeerConnection:(NSDictionary*)configuration
                 constraints:(NSDictionary*)constraints
                    eventCb:(webrtc_event_cb)eventCb
                    userData:(void*)userData
                      result:(WebrtcResult)result {
  BOOL isSysAudio = [configuration[@"isSysAudio"] boolValue];
  if (![configuration[@"isSysAudio"] isKindOfClass:[NSNumber class]]) {
    isSysAudio = NO;
  }
  RTCPeerConnectionFactory* factory =
      isSysAudio ? self.emptyPcFactory : self.peerConnectionFactory;
  RTCPeerConnection* peerConnection =
      [factory peerConnectionWithConfiguration:[self RTCConfiguration:configuration]
                                   constraints:[self parseMediaConstraints:constraints]
                                      delegate:self];

  peerConnection.remoteStreams = [NSMutableDictionary new];
  peerConnection.remoteTracks = [NSMutableDictionary new];
  peerConnection.dataChannels = [NSMutableDictionary new];

  NSString* peerConnectionId = [[NSUUID UUID] UUIDString];
  peerConnection.flutterId = peerConnectionId;

  WebrtcEventCallback* cb = [WebrtcEventCallback new];
  cb.cb = eventCb;
  cb.userData = userData;
  peerConnection.webrtcEventCallback = cb;

  self.peerConnections[peerConnectionId] = peerConnection;
  result(@{@"peerConnectionId" : peerConnectionId});
}

- (RTCPeerConnection*)peerConnectionForId:(NSString*)peerConnectionId {
  return self.peerConnections[peerConnectionId];
}

- (void)registerPeerConnection:(RTCPeerConnection*)pc
                        forId:(NSString*)peerConnectionId
                       eventCb:(webrtc_event_cb)eventCb
                       userData:(void*)userData {
  pc.flutterId = peerConnectionId;
  WebrtcEventCallback* cb = [WebrtcEventCallback new];
  cb.cb = eventCb;
  cb.userData = userData;
  pc.webrtcEventCallback = cb;
  if (peerConnectionId) self.peerConnections[peerConnectionId] = pc;
}

// 注意: RTCPeerConnectionDelegate 方法统一由 WebrtcRTCPeerConnection.mm 的 category
// (WebrtcPlugin (RTCPeerConnection)) 实现, 事件名对齐 win/linux C ABI
// (signalingState/iceConnectionState/iceGatheringState/onCandidate/peerConnectionState 等)。
// 不要在这里重复实现 —— ObjC 主类方法会覆盖 category, 若重复则事件名错误、Dart 无法解析。
@end

#pragma mark - C ABI 入口层(extern "C")

// 顶层 webrtc.h 的 38 个 webrtc_* 符号, 与 win/linux C ABI 同名同签名, dart 零改动。
// mac 实现 = 照抄 darwin ObjC 业务方法 + 把 FlutterResult/FlutterEventSink 换成 C 回调。

extern "C" {

#include <string.h>
#include <stdlib.h>

static WebrtcPlugin* WebrtcPluginSingleton(void) {
  WebrtcPlugin* p = [WebrtcPlugin sharedInstance];
  if (!p.peerConnectionFactory) [p initializeFactory];
  return p;
}

webrtc_handle webrtc_factory_create(void) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSLog(@"[DBG-factory_create] plugin=%p", p);
  return (__bridge void*)p;
}

void webrtc_factory_destroy(webrtc_handle factory) {
  // 单例常驻
}

/* 注册 factory 级事件回调(设备热插拔 onDeviceChange / 桌源增删改名等)。
 * 存进单例, postFactoryEvent 按需派发; 注册后立即补发一次 onDeviceChange(对齐 win/linux)。 */
int webrtc_factory_set_event_cb(webrtc_handle factory, webrtc_event_cb cb,
                                void* user_data) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  p.factoryEventCb = cb;
  p.factoryEventUd = user_data;
  [p postFactoryEvent:@{@"event" : @"onDeviceChange"}];
  return 0;
}

webrtc_handle webrtc_create_peer_connection(webrtc_handle factory,
                                            const char* configuration_json,
                                            const char* constraints_json,
                                            webrtc_event_cb on_event,
                                            void* user_data) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSLog(@"[DBG-createPC] plugin=%p factory=%p peerConnectionsCount=%lu",
        p, factory, (unsigned long)[p.peerConnections count]);
  NSDictionary* config = WebrtcParseJson(configuration_json);
  NSDictionary* constraints = WebrtcParseJson(constraints_json);
  __block RTCPeerConnection* created = nil;
  [p createPeerConnection:config ?: @{}
              constraints:constraints ?: @{}
                 eventCb:on_event
                 userData:user_data
                   result:^(id r) {
                     if (![r isKindOfClass:[WebrtcError class]] && r[@"peerConnectionId"]) {
                       created = p.peerConnections[r[@"peerConnectionId"]];
                     }
                   }];
  return (__bridge void*)created;
}

void webrtc_pc_destroy(webrtc_handle pc) {
  if (!pc) return;
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  [plugin.peerConnections removeObjectForKey:p.flutterId];
}

char* webrtc_get_user_media(webrtc_handle factory, const char* media_constraints_json) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSDictionary* c = WebrtcParseJson(media_constraints_json);
  // getUserMedia 需 TCC 权限 + 采集启动, 完成回调异步派发到主队列; 同步等待其完成
  // 30s 超时: macOS 上 CLI 进程可能弹不出权限对话框, 无限等待会卡死
  __block NSDictionary* out = nil;
  __block NSString* errMsg = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [p getUserMedia:c ?: @{} result:^(id r) {
    if ([r isKindOfClass:[WebrtcError class]]) {
      errMsg = ((WebrtcError*)r).message;
    } else {
      out = r;
    }
    dispatch_semaphore_signal(sem);
  }];
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
    errMsg = @"Timed out waiting for getUserMedia (30s)";
  }
  if (out) {
    return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                    encoding:NSUTF8StringEncoding]);
  }
  // 失败时返回 JSON 错误对象, 让 dart 侧能解析具体原因
  NSString* errJson = [NSString stringWithFormat:@"{\"error\":\"%@\"}",
      errMsg ?: @"getUserMedia failed"];
  return WebrtcMallocString(errJson);
}

void webrtc_stream_dispose(webrtc_handle factory, const char* stream_id) {
  if (!stream_id) return;
  WebrtcPlugin* p = WebrtcPluginSingleton();
  [p.localStreams removeObjectForKey:WebrtcCString(stream_id)];
}

char* webrtc_factory_get_rtp_sender_capabilities(webrtc_handle factory, const char* kind) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSDictionary* args = @{@"kind" : WebrtcCString(kind) ?: @""};
  __block NSDictionary* out = nil;
  [p peerConnectionGetRtpSenderCapabilities:args result:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

char* webrtc_factory_get_rtp_receiver_capabilities(webrtc_handle factory, const char* kind) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSDictionary* args = @{@"kind" : WebrtcCString(kind) ?: @""};
  __block NSDictionary* out = nil;
  [p peerConnectionGetRtpReceiverCapabilities:args result:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

char* webrtc_get_sources(webrtc_handle factory) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  __block NSDictionary* out = nil;
  [p getSources:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

int webrtc_select_audio_input(webrtc_handle factory, const char* device_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  __block int ok = 0;
  [p selectAudioInput:WebrtcCString(device_id) result:^(id r) {
    ok = [r isKindOfClass:[WebrtcError class]] ? 0 : 1;
  }];
  return ok;
}

int webrtc_select_audio_output(webrtc_handle factory, const char* device_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  __block int ok = 0;
  [p selectAudioOutput:WebrtcCString(device_id) result:^(id r) {
    ok = [r isKindOfClass:[WebrtcError class]] ? 0 : 1;
  }];
  return ok;
}

char* webrtc_create_local_media_stream(webrtc_handle factory) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  __block NSDictionary* out = nil;
  [p createLocalMediaStream:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

char* webrtc_media_stream_get_tracks(webrtc_handle factory, const char* stream_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  __block NSDictionary* out = nil;
  [p mediaStreamGetTracks:WebrtcCString(stream_id) result:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

void webrtc_media_stream_dispose(webrtc_handle factory, const char* stream_id) {
  if (!stream_id) return;
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSString* sid = WebrtcCString(stream_id);
  [p.localStreams removeObjectForKey:sid];
}

void webrtc_media_stream_track_dispose(webrtc_handle factory, const char* track_id) {
  if (!track_id) return;
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSString* tid = WebrtcCString(track_id);
  id<LocalTrack> track = p.localTracks[tid];
  [p.localTracks removeObjectForKey:tid];
}

int webrtc_media_stream_add_track(webrtc_handle factory, const char* stream_id,
                                  const char* track_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  RTCMediaStream* stream = p.localStreams[WebrtcCString(stream_id)];
  RTCMediaStreamTrack* track = [p trackForId:WebrtcCString(track_id) peerConnectionId:nil];
  if (!stream || !track) return 0;
  if ([track isKindOfClass:[RTCAudioTrack class]]) {
    [stream addAudioTrack:(RTCAudioTrack*)track];
  } else if ([track isKindOfClass:[RTCVideoTrack class]]) {
    [stream addVideoTrack:(RTCVideoTrack*)track];
  }
  return 1;
}

int webrtc_media_stream_remove_track(webrtc_handle factory, const char* stream_id,
                                     const char* track_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  RTCMediaStream* stream = p.localStreams[WebrtcCString(stream_id)];
  if (!stream) return 0;
  RTCMediaStreamTrack* track = [p trackForId:WebrtcCString(track_id) peerConnectionId:nil];
  if (!track) return 0;
  if ([track isKindOfClass:[RTCAudioTrack class]]) {
    [stream removeAudioTrack:(RTCAudioTrack*)track];
  } else if ([track isKindOfClass:[RTCVideoTrack class]]) {
    [stream removeVideoTrack:(RTCVideoTrack*)track];
  }
  return 1;
}

/* 开/关轨道(enabled), 0 成功(照 darwin MediaStreamTrack.setEnabled:)。 */
int webrtc_media_stream_track_set_enable(webrtc_handle factory, const char* track_id,
                                         int enabled) {
  if (!track_id) return -1;
  WebrtcPlugin* p = WebrtcPluginSingleton();
  RTCMediaStreamTrack* track = [p trackForId:WebrtcCString(track_id) peerConnectionId:nil];
  if (!track) return -1;
  track.isEnabled = (enabled != 0);
  return 0;
}

/* 设置音频轨道音量(0.0~1.0), 0 成功(照 darwin setVolume, 走 RTCAudioSource.volume)。 */
int webrtc_track_set_volume(webrtc_handle factory, const char* track_id, double volume) {
  if (!track_id) return -1;
  WebrtcPlugin* p = WebrtcPluginSingleton();
  RTCMediaStreamTrack* track = [p trackForId:WebrtcCString(track_id) peerConnectionId:nil];
  if (!track || ![track isKindOfClass:[RTCAudioTrack class]]) return -1;
  ((RTCAudioTrack*)track).source.volume = volume;
  return 0;
}

void webrtc_pc_close(webrtc_handle pc) {
  if (!pc) return;
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  // 走 category 的 peerConnectionClose(照抄 darwin): close + 清理
  // remoteStreams/remoteTracks/dataChannels
  [plugin peerConnectionClose:p];
}

void webrtc_pc_create_answer(webrtc_handle pc, const char* constraints_json,
                             webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  [plugin peerConnectionCreateAnswer:WebrtcParseJson(constraints_json) ?: @{}
                      peerConnection:p
                              result:WebrtcResultMake(user_data, cb)];
}

void webrtc_pc_set_local_description(webrtc_handle pc, const char* sdp, const char* type,
                                     webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCSdpType sdpType = [RTCSessionDescription typeForString:WebrtcCString(type)];
  RTCSessionDescription* desc =
      [[RTCSessionDescription alloc] initWithType:sdpType sdp:WebrtcCString(sdp)];
  [plugin peerConnectionSetLocalDescription:desc
                             peerConnection:p
                                     result:WebrtcResultMake(user_data, cb)];
}

void webrtc_pc_set_remote_description(webrtc_handle pc, const char* sdp, const char* type,
                                      webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCSdpType sdpType = [RTCSessionDescription typeForString:WebrtcCString(type)];
  RTCSessionDescription* desc =
      [[RTCSessionDescription alloc] initWithType:sdpType sdp:WebrtcCString(sdp)];
  [plugin peerConnectionSetRemoteDescription:desc
                              peerConnection:p
                                      result:WebrtcResultMake(user_data, cb)];
}

int webrtc_pc_add_ice_candidate(webrtc_handle pc, const char* candidate_json) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  NSDictionary* j = WebrtcParseJson(candidate_json);
  if (!j) return 0;
  RTCIceCandidate* candidate =
      [[RTCIceCandidate alloc] initWithSdp:j[@"candidate"]
                                     sdpMLineIndex:[j[@"sdpMLineIndex"] intValue]
                                    sdpMid:j[@"sdpMid"]];
  __block int ok = 0;
  [plugin peerConnectionAddICECandidate:candidate
                         peerConnection:p
                                 result:^(id r) {
                                   ok = [r isKindOfClass:[WebrtcError class]] ? 0 : 1;
                                 }];
  return ok;
}

char* webrtc_pc_add_track(webrtc_handle pc, const char* track_id, const char* stream_id) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCMediaStreamTrack* track = [plugin trackForId:WebrtcCString(track_id) peerConnectionId:nil];
  NSLog(@"[DBG-addTrack] plugin=%p pc=%p trackForId(%s)=%@  localTracksCount=%lu",
        plugin, p, track_id ?: "(null)", track ? @"found" : @"NIL",
        (unsigned long)[plugin.localTracks count]);
  NSArray* streamIds = stream_id ? @[ WebrtcCString(stream_id) ] : @[];
  RTCRtpSender* sender = [p addTrack:track streamIds:streamIds];
  if (!sender) {
    NSLog(@"[DBG-addTrack] addTrack 返回 nil -> 将抛 addTrack failed");
    return NULL;
  }
  NSDictionary* out = [plugin rtpSenderToMap:sender];
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_remove_track(webrtc_handle pc, const char* sender_id) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCRtpSender* sender = [plugin getRtpSenderById:p Id:WebrtcCString(sender_id)];
  BOOL ok = sender ? [p removeTrack:sender] : NO;
  NSDictionary* out = @{@"result" : @(ok)};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_get_senders(webrtc_handle pc) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  NSMutableArray* senders = [NSMutableArray array];
  for (RTCRtpSender* sender in p.senders) {
    [senders addObject:[plugin rtpSenderToMap:sender]];
  }
  NSDictionary* out = @{@"senders" : senders};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_get_transceivers(webrtc_handle pc) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  NSMutableArray* transceivers = [NSMutableArray array];
  for (RTCRtpTransceiver* transceiver in p.transceivers) {
    [transceivers addObject:[plugin transceiverToMap:transceiver]];
  }
  NSDictionary* out = @{@"transceivers" : transceivers};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_sender_set_parameters(webrtc_handle pc, const char* sender_id,
                                      const char* params_json) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCRtpSender* sender = [plugin getRtpSenderById:p Id:WebrtcCString(sender_id)];
  NSDictionary* params = WebrtcParseJson(params_json);
  BOOL ok = NO;
  if (sender && params) {
    [sender setParameters:[plugin updateRtpParameters:sender.parameters with:params]];
    ok = YES;
  }
  NSDictionary* out = @{@"result" : @(ok)};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

void webrtc_pc_transceiver_set_codec_preferences(webrtc_handle pc, const char* transceiver_id,
                                                 const char* codecs_json) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  NSDictionary* args = @{
    @"peerConnectionId" : p.flutterId ?: @"",
    @"transceiverId" : WebrtcCString(transceiver_id) ?: @"",
    @"codecs" : [NSJSONSerialization JSONObjectWithData:
                              [NSData dataWithBytes:codecs_json length:strlen(codecs_json ?: "")]
                                              options:0 error:nil] ?: @[],
  };
  [plugin transceiverSetCodecPreferences:args result:^(id r){}];
}

void webrtc_pc_get_stats(webrtc_handle pc, const char* track_id,
                         webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  if (track_id && track_id[0]) {
    [plugin peerConnectionGetStatsForTrackId:WebrtcCString(track_id)
                              peerConnection:p
                                      result:WebrtcResultMake(user_data, cb)];
  } else {
    [plugin peerConnectionGetStats:p result:WebrtcResultMake(user_data, cb)];
  }
}

/* ---- 主控/发送方补充 + 状态查询: 补齐 webrtc.h 里 dart 已绑定但此前缺实现的 _pc_* ----
 * 语义对照 win/linux C ABI 基线 + 照抄 darwin FlutterWebRTCPlugin.m 对应方法。 */

void webrtc_pc_create_offer(webrtc_handle pc, const char* constraints_json,
                            webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  [plugin peerConnectionCreateOffer:WebrtcParseJson(constraints_json) ?: @{}
                    peerConnection:p
                            result:WebrtcResultMake(user_data, cb)];
}

void webrtc_pc_get_local_description(webrtc_handle pc,
                                     webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  [plugin peerConnectionGetLocalDescription:p result:WebrtcResultMake(user_data, cb)];
}

void webrtc_pc_get_remote_description(webrtc_handle pc,
                                      webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  [plugin peerConnectionGetRemoteDescription:p result:WebrtcResultMake(user_data, cb)];
}

/* AddTransceiver(照抄 darwin addTransceiver): track_id 非空走 track 重载,
 * 否则按 media_type; init_json 经 mapToTransceiverInit 解码。 */
char* webrtc_pc_add_transceiver(webrtc_handle pc, const char* track_id,
                                const char* media_type, const char* init_json) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCMediaStreamTrack* track =
      track_id ? [plugin trackForId:WebrtcCString(track_id) peerConnectionId:nil] : nil;
  NSDictionary* initDict = init_json ? WebrtcParseJson(init_json) : nil;
  RTCRtpTransceiver* transceiver = nil;
  if (track) {
    if (initDict) {
      transceiver = [p addTransceiverWithTrack:track
                                          init:[plugin mapToTransceiverInit:initDict]];
    } else {
      transceiver = [p addTransceiverWithTrack:track];
    }
  } else if (media_type) {
    RTCRtpMediaType rtpMediaType = [plugin stringToRtpMediaType:WebrtcCString(media_type)];
    if (initDict) {
      transceiver = [p addTransceiverOfType:rtpMediaType
                                       init:[plugin mapToTransceiverInit:initDict]];
    } else {
      transceiver = [p addTransceiverOfType:rtpMediaType];
    }
  }
  if (!transceiver) return NULL;
  NSDictionary* out = [plugin transceiverToMap:transceiver];
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_get_receivers(webrtc_handle pc) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  NSMutableArray* receivers = [NSMutableArray array];
  for (RTCRtpReceiver* receiver in p.receivers) {
    [receivers addObject:[plugin receiverToMap:receiver]];
  }
  NSDictionary* out = @{@"receivers" : receivers};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

/* rtpSenderSetTrack(照抄 darwin): track_id 空 -> 传 nil 清空; 否则按 localTracks 取。 */
void webrtc_pc_sender_set_track(webrtc_handle pc, const char* sender_id,
                                const char* track_id,
                                webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  WebrtcResult result = WebrtcResultMake(user_data, cb);
  RTCRtpSender* sender = [plugin getRtpSenderById:p Id:WebrtcCString(sender_id)];
  if (!sender) {
    result([WebrtcError errorWithCode:@"rtpSenderSetTrackFailed"
                              message:@"Error: sender not found!" details:nil]);
    return;
  }
  RTCMediaStreamTrack* track = nil;
  if (track_id && track_id[0]) {
    track = [plugin trackForId:WebrtcCString(track_id) peerConnectionId:nil];
    if (!track) {
      result([WebrtcError errorWithCode:@"rtpSenderSetTrackFailed"
                                message:@"Error: track not found!" details:nil]);
      return;
    }
  }
  [sender setTrack:track];
  result(nil);
}

/* rtpSenderSetStreams(照抄 darwin): stream_ids_json 是 JSON 数组。 */
void webrtc_pc_sender_set_stream(webrtc_handle pc, const char* sender_id,
                                 const char* stream_ids_json,
                                 webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  WebrtcResult result = WebrtcResultMake(user_data, cb);
  RTCRtpSender* sender = [plugin getRtpSenderById:p Id:WebrtcCString(sender_id)];
  if (!sender) {
    result([WebrtcError errorWithCode:@"rtpSenderSetStreamsFailed"
                              message:@"Error: sender not found!" details:nil]);
    return;
  }
  NSArray* ids = [NSJSONSerialization JSONObjectWithData:
                              [NSData dataWithBytes:stream_ids_json
                                             length:strlen(stream_ids_json ?: "")]
                                              options:0 error:nil];
  if (![ids isKindOfClass:[NSArray class]]) ids = @[];
  [sender setStreamIds:ids];
  result(nil);
}

/* rtpTransceiverStop / GetCurrentDirection / SetDirection(照抄 darwin 同名方法)。 */
void webrtc_pc_transceiver_stop(webrtc_handle pc, const char* transceiver_id,
                                webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  WebrtcResult result = WebrtcResultMake(user_data, cb);
  RTCRtpTransceiver* transceiver = [plugin getRtpTransceiverById:p
                                                             Id:WebrtcCString(transceiver_id)];
  if (!transceiver) {
    result([WebrtcError errorWithCode:@"rtpTransceiverStopFailed"
                              message:@"Error: transceiver not found!" details:nil]);
    return;
  }
  [transceiver stopInternal];
  result(nil);
}

void webrtc_pc_transceiver_get_current_direction(
    webrtc_handle pc, const char* transceiver_id, webrtc_result_cb cb,
    void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  WebrtcResult result = WebrtcResultMake(user_data, cb);
  RTCRtpTransceiver* transcevier = [plugin getRtpTransceiverById:p
                                                             Id:WebrtcCString(transceiver_id)];
  if (!transcevier) {
    result([WebrtcError errorWithCode:@"rtpTransceiverGetCurrentDirectionFailed"
                              message:@"Error: transceiver not found!" details:nil]);
    return;
  }
  RTCRtpTransceiverDirection directionOut = transcevier.direction;
  if ([transcevier currentDirection:&directionOut]) {
    result(@{@"result" : [plugin transceiverDirectionString:directionOut]});
  } else {
    result(nil);
  }
}

void webrtc_pc_transceiver_set_direction(
    webrtc_handle pc, const char* transceiver_id, const char* direction,
    webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  WebrtcResult result = WebrtcResultMake(user_data, cb);
  RTCRtpTransceiver* transcevier = [plugin getRtpTransceiverById:p
                                                             Id:WebrtcCString(transceiver_id)];
  if (!transcevier) {
    result([WebrtcError errorWithCode:@"rtpTransceiverSetDirectionFailed"
                              message:@"Error: transceiver not found!" details:nil]);
    return;
  }
  [transcevier setDirection:[plugin stringToTransceiverDirection:WebrtcCString(direction)]
                      error:nil];
  result(nil);
}

/* SetConfiguration: 与 win/linux 对齐(参考实现本身即 TODO, 仅成功返回)。
 * 有合法配置时仍先落地 peerConnectionSetConfiguration。 */
void webrtc_pc_set_configuration(webrtc_handle pc, const char* configuration_json,
                                 webrtc_result_cb cb, void* user_data) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  NSDictionary* configDict = WebrtcParseJson(configuration_json);
  if (configDict) {
    [plugin peerConnectionSetConfiguration:[plugin RTCConfiguration:configDict]
                           peerConnection:p];
  }
  WebrtcResult result = WebrtcResultMake(user_data, cb);
  result(nil);
}

/* ---- 媒体流/ICE重启/DTMF/状态查询(对齐 win/linux webrtc.cc) ----
 * addStream/removeStream 在 plugin.localStreams 按 stream_id 查流; 返回 0 成功/-1 失败。 */
int webrtc_pc_add_stream(webrtc_handle pc, const char* stream_id) {
  if (!pc || !stream_id) return -1;
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCMediaStream* stream = plugin.localStreams[WebrtcCString(stream_id)];
  if (!stream) return -1;
  [p addStream:stream];
  return 0;
}

int webrtc_pc_remove_stream(webrtc_handle pc, const char* stream_id) {
  if (!pc || !stream_id) return -1;
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCMediaStream* stream = plugin.localStreams[WebrtcCString(stream_id)];
  if (!stream) return -1;
  [p removeStream:stream];
  return 0;
}

void webrtc_pc_restart_ice(webrtc_handle pc) {
  if (!pc) return;
  [(__bridge RTCPeerConnection*)pc restartIce];
}

/* DTMF: duration/gap 单位毫秒(按 win/linux), InsertDtmf 收秒(照 darwin 的 /1000.0)。 */
int webrtc_pc_sender_can_insert_dtmf(webrtc_handle pc, const char* sender_id) {
  if (!pc || !sender_id) return 0;
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCRtpSender* sender = [plugin getRtpSenderById:p Id:WebrtcCString(sender_id)];
  if (!sender || !sender.dtmfSender) return 0;
  return sender.dtmfSender.canInsertDtmf ? 1 : 0;
}

int webrtc_pc_sender_insert_dtmf(webrtc_handle pc, const char* sender_id,
                                 const char* tones, int duration, int gap) {
  if (!pc || !sender_id || !tones) return 0;
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCRtpSender* sender = [plugin getRtpSenderById:p Id:WebrtcCString(sender_id)];
  if (!sender || !sender.dtmfSender) return 0;
  return [sender.dtmfSender insertDtmf:WebrtcCString(tones)
                              duration:duration / 1000.0
                          interToneGap:gap / 1000.0] ? 1 : 0;
}

/* 状态同步查询 -> {"state":"..."}(对齐 win/linux), 失败返回 NULL。 */
char* webrtc_pc_get_signaling_state(webrtc_handle pc) {
  if (!pc) return NULL;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  NSDictionary* out =
      @{@"state" : [plugin stringForSignalingState:p.signalingState] ?: @""};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_get_ice_gathering_state(webrtc_handle pc) {
  if (!pc) return NULL;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  NSDictionary* out =
      @{@"state" : [plugin stringForICEGatheringState:p.iceGatheringState] ?: @""};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_get_ice_connection_state(webrtc_handle pc) {
  if (!pc) return NULL;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  NSDictionary* out =
      @{@"state" : [plugin stringForICEConnectionState:p.iceConnectionState] ?: @""};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

char* webrtc_pc_get_connection_state(webrtc_handle pc) {
  if (!pc) return NULL;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  NSDictionary* out =
      @{@"state" : [plugin stringForPeerConnectionState:p.connectionState] ?: @""};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

/* ---- E2EE 帧加密: 对应 mac/include/webrtc.h 的 frame_cryptor/key_provider 段 ----
 * createFrameCryptor 以 pc 句柄为第一参数, 其余以 factory 句柄 + constraints_json。
 * 与 win/linux C ABI 同名同签名、同 JSON 边界(字节数组是 JSON 数字数组)。
 * 状态事件经 factory 事件回调上报: {"event":"frameCryptionStateChanged",...} */

// 纯 JSON 进 → JSON 出的 frameCryptor/keyProvider 方法共用此包装(业务方法都同步回调)
static char* WebrtcFrameCryptorCall(WebrtcPlugin* p, const char* constraints_json,
                                    void (^call)(WebrtcPlugin*, NSDictionary*, WebrtcResult)) {
  NSDictionary* outDict = WebrtcParseJson(constraints_json) ?: @{};
  __block NSDictionary* out = nil;
  call(p, outDict, ^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  });
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

char* webrtc_frame_cryptor_factory_create_frame_cryptor(webrtc_handle pc,
                                                        const char* constraints_json) {
  NSDictionary* outDict = WebrtcParseJson(constraints_json) ?: @{};
  RTCPeerConnection* peerConnection = (__bridge RTCPeerConnection*)pc;
  __block NSDictionary* out = nil;
  [WebrtcPluginSingleton() frameCryptorFactoryCreateFrameCryptor:outDict
                                                  peerConnection:peerConnection
                                                         result:^(id r) {
                                                           if (![r isKindOfClass:[WebrtcError class]]) out = r;
                                                         }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

char* webrtc_frame_cryptor_set_key_index(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p frameCryptorSetKeyIndex:c result:result];
      });
}

char* webrtc_frame_cryptor_get_key_index(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p frameCryptorGetKeyIndex:c result:result];
      });
}

char* webrtc_frame_cryptor_set_enabled(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p frameCryptorSetEnabled:c result:result];
      });
}

char* webrtc_frame_cryptor_get_enabled(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p frameCryptorGetEnabled:c result:result];
      });
}

char* webrtc_frame_cryptor_dispose(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p frameCryptorDispose:c result:result];
      });
}

char* webrtc_frame_cryptor_factory_create_key_provider(webrtc_handle factory,
                                                       const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p frameCryptorFactoryCreateKeyProvider:c result:result];
      });
}

char* webrtc_key_provider_set_shared_key(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderSetSharedKey:c result:result];
      });
}

char* webrtc_key_provider_ratchet_shared_key(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderRatchetSharedKey:c result:result];
      });
}

char* webrtc_key_provider_export_shared_key(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderExportSharedKey:c result:result];
      });
}

char* webrtc_key_provider_set_key(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderSetKey:c result:result];
      });
}

char* webrtc_key_provider_ratchet_key(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderRatchetKey:c result:result];
      });
}

char* webrtc_key_provider_export_key(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderExportKey:c result:result];
      });
}

char* webrtc_key_provider_set_sif_trailer(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderSetSifTrailer:c result:result];
      });
}

char* webrtc_key_provider_dispose(webrtc_handle factory, const char* constraints_json) {
  return WebrtcFrameCryptorCall(WebrtcPluginSingleton(), constraints_json,
      ^(WebrtcPlugin* p, NSDictionary* c, WebrtcResult result) {
        [p keyProviderDispose:c result:result];
      });
}

char* webrtc_get_sys_audio_media(webrtc_handle factory, const char* params_json) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSDictionary* params = WebrtcParseJson(params_json) ?: @{};
  NSError* error = nil;
  NSMutableDictionary* out = [[SysAudioTrackManager sharedInstance]
      getSysAudioMediaWithPlugin:p
                        deviceId:params[@"deviceId"]
                        streamId:params[@"streamId"]
              enablePcmRecording:[params[@"enablePcmRecording"] boolValue]
                     pcmFilePath:params[@"pcmFilePath"]
                           error:&error];
  if (!out) return NULL;
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

void webrtc_release_sys_audio_media(webrtc_handle factory, const char* stream_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  [[SysAudioTrackManager sharedInstance] releaseSysAudioMediaWithPlugin:p
                                                               streamId:WebrtcCString(stream_id)];
}

int webrtc_enable_sys_audio_pcm_recording(webrtc_handle factory, int enable,
                                          const char* file_path) {
  SysAudioTrackManager* m = [SysAudioTrackManager sharedInstance];
  m.enablePcmRecording = (enable != 0);
  m.pcmFilePath = WebrtcCString(file_path);
  return 1;
}

char* webrtc_get_desktop_sources(webrtc_handle factory, const char* types_json) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSArray* types = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:types_json
                                                                        length:strlen(types_json ?: "")]
                                                   options:0 error:nil];
  if (![types isKindOfClass:[NSArray class]]) types = @[];
  __block NSDictionary* out = nil;
  [p getDesktopSources:@{@"types" : types} result:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

/* updateDesktopSources: 不强制重载的源列表刷新(照抄 WebrtcRTCDesktopCapturer.mm)。
 * 源增删/改名经 factory 事件回调上报。返回 {"result":true}, 失败 NULL。 */
char* webrtc_update_desktop_sources(webrtc_handle factory, const char* types_json) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSArray* types = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:types_json
                                                                        length:strlen(types_json ?: "")]
                                                   options:0 error:nil];
  if (![types isKindOfClass:[NSArray class]]) types = @[];
  __block NSDictionary* out = nil;
  [p updateDesktopSources:@{@"types" : types} result:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

char* webrtc_get_display_media(webrtc_handle factory, const char* constraints_json) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSDictionary* c = WebrtcParseJson(constraints_json) ?: @{};
  __block NSDictionary* out = nil;
  [p getDisplayMedia:c result:^(id r) {
    if (![r isKindOfClass:[WebrtcError class]]) out = r;
  }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

char* webrtc_create_data_channel(webrtc_handle pc, const char* label, const char* init_json) {
  RTCPeerConnection* p = (__bridge RTCPeerConnection*)pc;
  WebrtcPlugin* plugin = WebrtcPluginSingleton();
  NSDictionary* j = WebrtcParseJson(init_json) ?: @{};
  RTCDataChannelConfiguration* config = [RTCDataChannelConfiguration new];
  if (j[@"id"]) config.channelId = [j[@"id"] intValue];
  if (j[@"ordered"]) config.isOrdered = [j[@"ordered"] boolValue];
  if (j[@"maxRetransmits"]) config.maxRetransmits = [j[@"maxRetransmits"] intValue];
  if (j[@"negotiated"]) config.isNegotiated = [j[@"negotiated"] boolValue];
  if (j[@"protocol"]) config.protocol = j[@"protocol"];
  __block NSDictionary* out = nil;
  [plugin createDataChannel:p.flutterId ?: @""
                      label:WebrtcCString(label)
                     config:config
                    eventCb:NULL
                   userData:NULL
                     result:^(id r) {
                       if (![r isKindOfClass:[WebrtcError class]]) out = r;
                     }];
  return WebrtcMallocString(out ? [[NSString alloc] initWithData:WebrtcJsonData(out)
                                                        encoding:NSUTF8StringEncoding] : nil);
}

int webrtc_data_channel_set_callback(webrtc_handle factory, const char* flutter_id,
                                     webrtc_event_cb cb, void* user_data) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSString* fid = WebrtcCString(flutter_id);
  for (RTCPeerConnection* pc in p.peerConnections.allValues) {
    RTCDataChannel* dc = pc.dataChannels[fid];
    if (dc) {
      WebrtcEventCallback* ec = [WebrtcEventCallback new];
      ec.cb = cb;
      ec.userData = user_data;
      dc.webrtcEventCallback = ec;
      if (dc.eventQueue) {
        for (id ev in dc.eventQueue) [ec post:ev];
        dc.eventQueue = nil;
      }
      return 1;
    }
  }
  return 0;
}

int webrtc_data_channel_send(webrtc_handle factory, const char* flutter_id, int is_binary,
                             const uint8_t* data, int len) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSString* fid = WebrtcCString(flutter_id);
  for (RTCPeerConnection* pc in p.peerConnections.allValues) {
    RTCDataChannel* dc = pc.dataChannels[fid];
    if (dc) {
      NSData* payload = [NSData dataWithBytes:data length:len];
      RTCDataBuffer* buffer = [[RTCDataBuffer alloc] initWithData:payload
                                                         isBinary:is_binary != 0];
      return [dc sendData:buffer] ? 1 : 0;
    }
  }
  return 0;
}

char* webrtc_data_channel_buffered_amount(webrtc_handle factory, const char* flutter_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSString* fid = WebrtcCString(flutter_id);
  uint64_t amount = 0;
  for (RTCPeerConnection* pc in p.peerConnections.allValues) {
    RTCDataChannel* dc = pc.dataChannels[fid];
    if (dc) {
      amount = dc.bufferedAmount;
      break;
    }
  }
  NSDictionary* out = @{@"bufferedAmount" : @(amount)};
  return WebrtcMallocString([[NSString alloc] initWithData:WebrtcJsonData(out)
                                                  encoding:NSUTF8StringEncoding]);
}

void webrtc_data_channel_close(webrtc_handle factory, const char* flutter_id) {
  WebrtcPlugin* p = WebrtcPluginSingleton();
  NSString* fid = WebrtcCString(flutter_id);
  for (RTCPeerConnection* pc in p.peerConnections.allValues) {
    RTCDataChannel* dc = pc.dataChannels[fid];
    if (dc) {
      [dc close];
      [pc.dataChannels removeObjectForKey:fid];
      break;
    }
  }
}

void webrtc_free_string(char* s) {
  if (s) free(s);
}

} // extern "C"
