/* WebrtcRTCPeerConnection.h — mac 独立 C ABI 的 PC 业务 category。
 * 照抄自 common/darwin/Classes/FlutterRTCPeerConnection.h，去 Flutter：
 *   - RTCPeerConnection (Flutter) 的 eventSink/eventChannel → webrtcEventCallback (C ABI)
 *   - FlutterResult → WebrtcResult；FlutterStreamHandler 协议删除
 * 业务方法签名与 darwin 一致。
 */
#ifndef WEBRTC_RTC_PEERCONNECTION_H
#define WEBRTC_RTC_PEERCONNECTION_H

#import "WebrtcPlugin.h"

@interface RTCPeerConnection (Flutter)
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString*, RTCDataChannel*>* dataChannels;
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString*, RTCMediaStream*>* remoteStreams;
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString*, RTCMediaStreamTrack*>* remoteTracks;
@property(nonatomic, strong, nonnull) NSString* flutterId;
/* 事件路由到 C ABI (替代 darwin 的 FlutterEventSink/EventChannel) */
@property(nonatomic, strong, nullable) WebrtcEventCallback* webrtcEventCallback;
@end

@interface WebrtcPlugin (RTCPeerConnection)

- (void)peerConnectionClose:(nonnull RTCPeerConnection*)peerConnection;

- (void)peerConnectionCreateOffer:(nonnull NSDictionary*)constraints
                   peerConnection:(nonnull RTCPeerConnection*)peerConnection
                           result:(nonnull WebrtcResult)result;

- (void)peerConnectionCreateAnswer:(nonnull NSDictionary*)constraints
                    peerConnection:(nonnull RTCPeerConnection*)peerConnection
                            result:(nonnull WebrtcResult)result;

- (void)peerConnectionSetLocalDescription:(nonnull RTCSessionDescription*)sdp
                           peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                   result:(nonnull WebrtcResult)result;

- (void)peerConnectionSetRemoteDescription:(nonnull RTCSessionDescription*)sdp
                            peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                    result:(nonnull WebrtcResult)result;

- (void)peerConnectionAddICECandidate:(nonnull RTCIceCandidate*)candidate
                       peerConnection:(nonnull RTCPeerConnection*)peerConnection
                               result:(nonnull WebrtcResult)result;

- (void)peerConnectionGetStats:(nonnull RTCPeerConnection*)peerConnection
                        result:(nonnull WebrtcResult)result;

- (void)peerConnectionGetStatsForTrackId:(nonnull NSString*)trackID
                          peerConnection:(nonnull RTCPeerConnection*)peerConnection
                                  result:(nonnull WebrtcResult)result;

- (void)peerConnectionGetLocalDescription:(nonnull RTCPeerConnection*)peerConnection
                                   result:(nonnull WebrtcResult)result;

- (void)peerConnectionGetRemoteDescription:(nonnull RTCPeerConnection*)peerConnection
                                    result:(nonnull WebrtcResult)result;

- (nonnull RTCMediaConstraints*)parseMediaConstraints:(nonnull NSDictionary*)constraints;

- (void)peerConnectionSetConfiguration:(nonnull RTCConfiguration*)configuration
                        peerConnection:(nonnull RTCPeerConnection*)peerConnection;

- (void)peerConnectionGetRtpReceiverCapabilities:(nonnull NSDictionary*)argsMap
                                          result:(nonnull WebrtcResult)result;

- (void)peerConnectionGetRtpSenderCapabilities:(nonnull NSDictionary*)argsMap
                                        result:(nonnull WebrtcResult)result;

- (void)transceiverSetCodecPreferences:(nonnull NSDictionary*)argsMap
                                result:(nonnull WebrtcResult)result;

- (nullable NSString*)stringForSignalingState:(RTCSignalingState)state;
- (nullable NSString*)stringForICEGatheringState:(RTCIceGatheringState)state;
- (nullable NSString*)stringForICEConnectionState:(RTCIceConnectionState)state;
- (nullable NSString*)stringForPeerConnectionState:(RTCPeerConnectionState)state;

@end

#endif /* WEBRTC_RTC_PEERCONNECTION_H */
