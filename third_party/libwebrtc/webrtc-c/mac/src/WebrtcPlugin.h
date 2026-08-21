/* WebrtcPlugin.h — mac 独立 C ABI 的单例中枢。
 *
 * 照抄自 common/darwin/Classes/FlutterWebRTCPlugin.h，去掉 Flutter 协议
 * (FlutterPlugin / FlutterStreamHandler / FlutterMethodChannel / FlutterEventChannel /
 *  FlutterResult / FlutterEventSink)，改为 C ABI 回调 (webrtc_event_cb / webrtc_result_cb)。
 * 业务过程(dict/工厂/方法)保持与 darwin 一致；平台无关字段已删(渲染/录制/加密/ReplayKit)。
 */
#ifndef WEBRTC_PLUGIN_H
#define WEBRTC_PLUGIN_H

#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import "LocalTrack.h"

#import "webrtc/webrtc.h" /* webrtc_event_cb / webrtc_result_cb 定义 */

@class WebrtcRTCVideoRenderer; /* 未迁移, 占位避免头引用缺失 */

/* ---- 事件回调承载: 替代 darwin 的 FlutterEventSink ----
 * 照抄 darwin 里 postEvent(sink, dict) 的语义: 转 JSON、派发主线程、交给 C 函数指针。
 * 二进制数据通道消息用 post:binary: 直传 NSData 指针, 不走 base64。
 */
@interface WebrtcEventCallback : NSObject
@property(nonatomic) webrtc_event_cb cb;
@property(nonatomic) void* userData;
/* 把 NSDictionary 事件转 JSON 后回调(替代 postEvent)。主线程派发与 darwin 一致。 */
- (void)post:(nonnull NSDictionary*)event;
/* 带二进制附件的版本: binary 非 nil 时直传 NSData.bytes, 不序列化到 JSON 的 data 字段。
   此时 JSON 的 "data" 字段为空串。 */
- (void)post:(nonnull NSDictionary*)event binary:(nullable NSData*)binary;
/* 已是 JSON 字符串时直接回调。 */
- (void)postString:(nonnull NSString*)json;
@end

/* ---- 错误承载: 替代 darwin 的 FlutterError ----
 * C ABI 层检测到本类型即视为错误(err!=0)。业务方法里保持 result([WebrtcError ...]) 写法。
 */
@interface WebrtcError : NSObject
@property(nonatomic, strong, nullable) NSString* code;
@property(nonatomic, strong, nullable) NSString* message;
@property(nonatomic, strong, nullable) id details;
+ (nonnull instancetype)errorWithCode:(nullable NSString*)code
                              message:(nullable NSString*)message
                              details:(nullable id)details;
@end

/* ---- 异步结果承载: 替代 darwin 的 FlutterResult ----
 * 参数为 NSDictionary / NSString / nil(成功)。若为 WebrtcError 实例则视为失败。
 * C ABI 层包出该 block, 序列化后调 webrtc_result_cb。
 */
typedef void (^WebrtcResult)(id _Nullable result);

/* 由 C ABI 层创建结果的包装 block, 替代 result(userData, err, json) 的手写。
 * 用法:
 *   WebrtcResult result = WebrtcResultMake(userData, cb);
 *   业务方法里 result(@{...}) / result(nil) / result([WebrtcError ...]) 均支持。
 */
extern WebrtcResult WebrtcResultMake(void* _Nonnull userData,
                                     webrtc_result_cb _Nullable cb);

typedef void (^CompletionHandler)(void);
typedef void (^CapturerStopHandler)(CompletionHandler _Nonnull handler);

@interface WebrtcPlugin : NSObject <RTCPeerConnectionDelegate,
                                    RTCAudioDeviceModuleDelegate,
                                    RTCDesktopMediaListDelegate,
                                    RTCDesktopCapturerDelegate>

@property(nonatomic, strong, nullable) RTCPeerConnectionFactory* peerConnectionFactory;
@property(nonatomic, strong, nullable) RTCPeerConnectionFactory* emptyPcFactory;
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSString*, RTCPeerConnection*>* peerConnections;
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSString*, RTCMediaStream*>* localStreams;
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSString*, id<LocalTrack>>* localTracks;
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSString*, CapturerStopHandler>* videoCapturerStopHandlers;

/* E2EE 帧加密注册表(照抄 darwin FlutterWebRTCPlugin 的 frameCryptors/keyProviders)。
 * 状态事件经 factoryEventCb 上报(factory.dart 路由给 FrameCryptorFfi), 不用 per-cryptor 回调。 */
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSString*, RTCFrameCryptor*>* frameCryptors;
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSString*, RTCFrameCryptorKeyProvider*>* keyProviders;

@property(nonatomic, strong, nullable) AudioManager* audioManager;

/* factory 级事件回调(设备热插拔 onDeviceChange / 桌源增删改名等),
 * 由 C ABI 的 webrtc_factory_set_event_cb 设置, postFactoryEvent 派发。 */
@property(nonatomic) webrtc_event_cb factoryEventCb;
@property(nonatomic) void* factoryEventUd;
- (void)postFactoryEvent:(nonnull NSDictionary*)event;

/* 工厂初始化(替代 darwin initialize:)。networkIgnoreMask 可传 nil。 */
- (void)initializeFactory;
- (void)initializeFactoryWithNetworkIgnoreMask:(nullable NSArray*)networkIgnoreMask
                         bypassVoiceProcessing:(BOOL)bypassVoiceProcessing
                                      severity:(nullable NSString*)severityStr;

/* ---- 与 darwin 同名同签名的业务方法, 保留原逻辑, 仅签名里 result 换成 WebrtcResult ---- */
- (nullable RTCMediaStream*)streamForId:(nonnull NSString*)streamId
                        peerConnectionId:(nullable NSString*)peerConnectionId;
- (nullable RTCMediaStreamTrack*)trackForId:(nonnull NSString*)trackId
                            peerConnectionId:(nullable NSString*)peerConnectionId;
- (nullable RTCRtpSender*)getRtpSenderById:(nonnull RTCPeerConnection*)peerConnection
                                         Id:(nonnull NSString*)Id;
- (nullable RTCRtpReceiver*)getRtpReceiverById:(nonnull RTCPeerConnection*)peerConnection
                                             Id:(nonnull NSString*)Id;
- (nullable RTCRtpTransceiver*)getRtpTransceiverById:(nonnull RTCPeerConnection*)peerConnection
                                                   Id:(nullable NSString*)Id;
- (void)ensureAudioSession;
- (nullable NSDictionary*)rtpSenderToMap:(nonnull RTCRtpSender*)sender;
- (nullable NSDictionary*)rtpParametersToMap:(nonnull RTCRtpParameters*)parameters;
- (nullable NSDictionary*)dtmfSenderToMap:(nullable id<RTCDtmfSender>)dtmf
                                       Id:(nonnull NSString*)Id;
- (nullable RTCRtpParameters*)updateRtpParameters:(nonnull RTCRtpParameters*)parameters
                                             with:(nonnull NSDictionary*)newParameters;

- (nullable NSDictionary*)mediaStreamToMap:(nonnull RTCMediaStream*)stream
                                   ownerTag:(nullable NSString*)ownerTag;
- (nullable NSDictionary*)mediaTrackToMap:(nonnull RTCMediaStreamTrack*)track;
- (nullable NSDictionary*)receiverToMap:(nonnull RTCRtpReceiver*)receiver;
- (nullable NSDictionary*)transceiverToMap:(nonnull RTCRtpTransceiver*)transceiver;
- (RTCRtpMediaType)stringToRtpMediaType:(nonnull NSString*)type;
- (RTCRtpTransceiverDirection)stringToTransceiverDirection:(nonnull NSString*)type;
- (nullable RTCRtpEncodingParameters*)mapToEncoding:(nonnull NSDictionary*)map;
- (nullable RTCRtpTransceiverInit*)mapToTransceiverInit:(nonnull NSDictionary*)map;

- (void)getUserMedia:(nonnull NSDictionary*)constraints
              result:(nonnull WebrtcResult)result;
- (void)getDisplayMedia:(nonnull NSDictionary*)constraints
                 result:(nonnull WebrtcResult)result;
- (void)updateDesktopSources:(nonnull NSDictionary*)argsMap
                      result:(nonnull WebrtcResult)result;
- (void)createLocalMediaStream:(nonnull WebrtcResult)result;
- (void)getSources:(nonnull WebrtcResult)result;
- (void)selectAudioInput:(nullable NSString*)deviceId
                  result:(nonnull WebrtcResult)result;
- (void)selectAudioOutput:(nullable NSString*)deviceId
                   result:(nonnull WebrtcResult)result;
- (void)mediaStreamGetTracks:(nonnull NSString*)streamId
                      result:(nonnull WebrtcResult)result;
- (void)createPeerConnection:(nonnull NSDictionary*)configuration
                 constraints:(nonnull NSDictionary*)constraints
                  eventCb:(webrtc_event_cb)eventCb
                  userData:(void*)userData
                      result:(nonnull WebrtcResult)result;

/* C ABI 入口的注册表辅助(Darwin 原在 handleMethodCall 里内联, 这里抽出来供 C ABI 层复用) */
- (nullable RTCPeerConnection*)peerConnectionForId:(nonnull NSString*)peerConnectionId;
- (void)registerPeerConnection:(nonnull RTCPeerConnection*)pc
                        forId:(nonnull NSString*)peerConnectionId
                       eventCb:(webrtc_event_cb)eventCb
                       userData:(void*)userData;

/* ---- E2EE FrameCryptor/KeyProvider 业务方法(照抄 darwin FlutterWebRTCPlugin (FrameCryptor),
 *      实现在 WebrtcRTCFrameCryptor.mm)。与 darwin 的两处差异:
 *      - create 方法不再按 peerConnectionId 查表, 直接收 RTCPeerConnection* 指针;
 *      - 字节数组(ratchetSalt/key/sifTrailer/返回的 key)在 C 边界是 JSON 数字数组,
 *        darwin 的 FlutterStandardTypedData 换成 NSData(WebrtcDataFromJsonArr/ArrFromData)。 ---- */
- (void)frameCryptorFactoryCreateFrameCryptor:(nonnull NSDictionary*)constraints
                               peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                       result:(nonnull WebrtcResult)result;
- (void)frameCryptorSetKeyIndex:(nonnull NSDictionary*)constraints
                         result:(nonnull WebrtcResult)result;
- (void)frameCryptorGetKeyIndex:(nonnull NSDictionary*)constraints
                         result:(nonnull WebrtcResult)result;
- (void)frameCryptorSetEnabled:(nonnull NSDictionary*)constraints
                        result:(nonnull WebrtcResult)result;
- (void)frameCryptorGetEnabled:(nonnull NSDictionary*)constraints
                        result:(nonnull WebrtcResult)result;
- (void)frameCryptorDispose:(nonnull NSDictionary*)constraints
                     result:(nonnull WebrtcResult)result;
- (void)frameCryptorFactoryCreateKeyProvider:(nonnull NSDictionary*)constraints
                                      result:(nonnull WebrtcResult)result;
- (void)keyProviderSetSharedKey:(nonnull NSDictionary*)constraints
                         result:(nonnull WebrtcResult)result;
- (void)keyProviderRatchetSharedKey:(nonnull NSDictionary*)constraints
                             result:(nonnull WebrtcResult)result;
- (void)keyProviderExportSharedKey:(nonnull NSDictionary*)constraints
                            result:(nonnull WebrtcResult)result;
- (void)keyProviderSetKey:(nonnull NSDictionary*)constraints
                   result:(nonnull WebrtcResult)result;
- (void)keyProviderRatchetKey:(nonnull NSDictionary*)constraints
                       result:(nonnull WebrtcResult)result;
- (void)keyProviderExportKey:(nonnull NSDictionary*)constraints
                      result:(nonnull WebrtcResult)result;
- (void)keyProviderSetSifTrailer:(nonnull NSDictionary*)constraints
                          result:(nonnull WebrtcResult)result;
- (void)keyProviderDispose:(nonnull NSDictionary*)constraints
                    result:(nonnull WebrtcResult)result;

+ (nullable WebrtcPlugin*)sharedInstance;

@end

/* ---- 已迁移到 mac 的 category 声明(darwin 同款, 去 Flutter) ----
 * RTCPeerConnection (Flutter) 里 eventSink/eventChannel → WebrtcEventCallback*。
 * 各 category 的头文件: WebrtcRTCPeerConnection.h / WebrtcRTCDataChannel.h(见对应 .mm)。
 */
#endif /* WEBRTC_PLUGIN_H */
