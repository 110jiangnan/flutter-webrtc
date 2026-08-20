/* WebrtcRTCDataChannel.h — 照抄 FlutterRTCDataChannel.h, 去 Flutter。
 * RTCDataChannel (Flutter) 的 eventSink/eventChannel → webrtcEventCallback(C ABI 回调)。
 */
#ifndef WEBRTC_RTC_DATA_CHANNEL_H
#define WEBRTC_RTC_DATA_CHANNEL_H

#import "WebrtcPlugin.h"

@interface RTCDataChannel (Flutter)
@property(nonatomic, strong, nonnull) NSString* peerConnectionId;
@property(nonatomic, strong, nonnull) NSString* flutterChannelId;
@property(nonatomic, strong, nullable) WebrtcEventCallback* webrtcEventCallback;
@property(nonatomic, strong, nullable) NSArray<id>* eventQueue;
@end

@interface WebrtcPlugin (RTCDataChannel) <RTCDataChannelDelegate>

- (void)createDataChannel:(nonnull NSString*)peerConnectionId
                    label:(nonnull NSString*)label
                   config:(nonnull RTCDataChannelConfiguration*)config
                  eventCb:(webrtc_event_cb)eventCb
                 userData:(void*)userData
                   result:(nonnull WebrtcResult)result;

- (void)dataChannelClose:(nonnull NSString*)peerConnectionId
           dataChannelId:(nonnull NSString*)dataChannelId;

- (void)dataChannelSend:(nonnull NSString*)peerConnectionId
          dataChannelId:(nonnull NSString*)dataChannelId
                   data:(nonnull id)data
                   type:(nonnull NSString*)type;

- (void)dataChannelGetBufferedAmount:(nonnull NSString*)peerConnectionId
                        dataChannelId:(nonnull NSString*)dataChannelId
                               result:(nonnull WebrtcResult)result;

@end

#endif /* WEBRTC_RTC_DATA_CHANNEL_H */
