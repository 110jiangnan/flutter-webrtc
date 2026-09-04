/* WebrtcRTCDataChannel.mm — 照抄 FlutterRTCDataChannel.m, 去 Flutter。
 * 差异:
 *  - eventSink/eventChannel → webrtcEventCallback (C ABI 回调承载 WebrtcEventCallback)
 *  - createDataChannel 不再需要 FlutterBinaryMessenger 建 FlutterEventChannel,
 *    改为接收 eventCb+userData 直接构造 WebrtcEventCallback
 *  - didReceiveMessageWithBuffer 里二进制数据: darwin 包 FlutterStandardTypedData,
 *    mac 直接放 NSData(由 WebrtcEventCallback 序列化为 base64 跨边界)
 */
#import "WebrtcRTCDataChannel.h"
#import "WebrtcRTCPeerConnection.h"
#import <WebRTC/RTCDataChannelConfiguration.h>
#import <objc/runtime.h>

@implementation RTCDataChannel (Flutter)

- (NSString*)peerConnectionId {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setPeerConnectionId:(NSString*)peerConnectionId {
  objc_setAssociatedObject(self, @selector(peerConnectionId), peerConnectionId,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (WebrtcEventCallback*)webrtcEventCallback {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setWebrtcEventCallback:(WebrtcEventCallback*)webrtcEventCallback {
  objc_setAssociatedObject(self, @selector(webrtcEventCallback), webrtcEventCallback,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSArray<id>*)eventQueue {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setEventQueue:(NSArray<id>*)eventQueue {
  objc_setAssociatedObject(self, @selector(eventQueue), eventQueue,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString*)flutterChannelId {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setFlutterChannelId:(NSString*)flutterChannelId {
  objc_setAssociatedObject(self, @selector(flutterChannelId), flutterChannelId,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@implementation WebrtcPlugin (RTCDataChannel)

- (void)createDataChannel:(nonnull NSString*)peerConnectionId
                    label:(NSString*)label
                   config:(RTCDataChannelConfiguration*)config
                  eventCb:(webrtc_event_cb)eventCb
                 userData:(void*)userData
                   result:(nonnull WebrtcResult)result {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  RTCDataChannel* dataChannel = [peerConnection dataChannelForLabel:label configuration:config];

  if (nil != dataChannel) {
    dataChannel.peerConnectionId = peerConnectionId;
    NSString* flutterId = [[NSUUID UUID] UUIDString];
    peerConnection.dataChannels[flutterId] = dataChannel;
    dataChannel.flutterChannelId = flutterId;
    dataChannel.delegate = self;
    @synchronized(dataChannel) {
      dataChannel.eventQueue = nil;
      WebrtcEventCallback* eventCallback = [WebrtcEventCallback new];
      eventCallback.cb = eventCb;
      eventCallback.userData = userData;
      dataChannel.webrtcEventCallback = eventCallback;
    }

    result(@{
      @"label" : label,
      @"id" : [NSNumber numberWithInt:dataChannel.channelId],
      @"flutterId" : flutterId
    });
  }
}

- (void)dataChannelClose:(nonnull NSString*)peerConnectionId
           dataChannelId:(nonnull NSString*)dataChannelId {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  NSMutableDictionary* dataChannels = peerConnection.dataChannels;
  RTCDataChannel* dataChannel = dataChannels[dataChannelId];
  if (dataChannel) {
    [dataChannel close];
    [dataChannels removeObjectForKey:dataChannelId];
    @synchronized(dataChannel) {
      dataChannel.webrtcEventCallback = nil;
    }
  }
}

- (void)dataChannelGetBufferedAmount:(nonnull NSString*)peerConnectionId
                        dataChannelId:(nonnull NSString*)dataChannelId
                               result:(nonnull WebrtcResult)result {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  RTCDataChannel* dataChannel = peerConnection.dataChannels[dataChannelId];
  if (dataChannel == nil || dataChannel.readyState != RTCDataChannelStateOpen) {
    result([WebrtcError
        errorWithCode:[NSString stringWithFormat:@"%@Failed", @"dataChannelGetBufferedAmount"]
              message:[NSString stringWithFormat:@"Error: dataChannel not found or not opened!"]
              details:nil]);
  } else {
    result(@{@"bufferedAmount" : @(dataChannel.bufferedAmount)});
  }
}

- (void)dataChannelSend:(nonnull NSString*)peerConnectionId
          dataChannelId:(nonnull NSString*)dataChannelId
                   data:(id)data
                   type:(NSString*)type {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  RTCDataChannel* dataChannel = peerConnection.dataChannels[dataChannelId];

  // darwin 二进制是 FlutterStandardTypedData(C ABI 层已转成 NSData)
  NSData* bytes = [type isEqualToString:@"binary"] ? (NSData*)data
                                                   : [data dataUsingEncoding:NSUTF8StringEncoding];

  RTCDataBuffer* buffer = [[RTCDataBuffer alloc] initWithData:bytes
                                                     isBinary:[type isEqualToString:@"binary"]];
  [dataChannel sendData:buffer];
}

- (NSString*)stringForDataChannelState:(RTCDataChannelState)state {
  switch (state) {
    case RTCDataChannelStateConnecting:
      return @"connecting";
    case RTCDataChannelStateOpen:
      return @"open";
    case RTCDataChannelStateClosing:
      return @"closing";
    case RTCDataChannelStateClosed:
      return @"closed";
  }
  return nil;
}

- (void)sendEvent:(id)event withChannel:(RTCDataChannel*)channel {
  [self sendEvent:event binary:nil withChannel:channel];
}

- (void)sendEvent:(id)event binary:(NSData*)binary withChannel:(RTCDataChannel*)channel {
  // 对齐上游 darwin: eventQueue/回调在回调线程与主线程(创建/关闭)间并发访问,
  // 用 @synchronized(channel) 保护。webrtcEventCallback 就绪后事件直发不走队列。
  @synchronized(channel) {
    if (channel.webrtcEventCallback) {
      [channel.webrtcEventCallback post:event binary:binary];
    } else {
      if (!channel.eventQueue) {
        channel.eventQueue = [NSMutableArray array];
      }
      // 队列暂存时 binary 放 event 的 data 字段(base64 兜底)
      if (binary) {
        NSMutableDictionary* m = [event mutableCopy];
        m[@"data"] = binary;
        event = m;
      }
      channel.eventQueue = [channel.eventQueue arrayByAddingObject:event];
    }
  }
}

#pragma mark - RTCDataChannelDelegate methods

- (void)dataChannelDidChangeState:(RTCDataChannel*)channel {
  [self sendEvent:@{
    @"event" : @"dataChannelStateChanged",
    @"id" : [NSNumber numberWithInt:channel.channelId],
    @"state" : [self stringForDataChannelState:channel.readyState]
  }
      withChannel:channel];
}

- (void)dataChannel:(RTCDataChannel*)channel didReceiveMessageWithBuffer:(RTCDataBuffer*)buffer {
  NSString* type;
  id data;
  NSData* binary = nil;
  if (buffer.isBinary) {
    type = @"binary";
    data = @"";  // 二进制数据走 binary 指针, JSON 里放空串
    binary = buffer.data;
  } else {
    type = @"text";
    data = [[NSString alloc] initWithData:buffer.data encoding:NSUTF8StringEncoding];
  }

  [self sendEvent:@{
    @"event" : @"dataChannelReceiveMessage",
    @"id" : [NSNumber numberWithInt:channel.channelId],
    @"type" : type,
    @"data" : (data ? data : [NSNull null])
  }
        binary:binary
      withChannel:channel];
}

- (void)dataChannel:(RTCDataChannel*)channel didChangeBufferedAmount:(uint64_t)amount {
  [self sendEvent:@{
    @"event" : @"dataChannelBufferedAmountChange",
    @"id" : [NSNumber numberWithInt:channel.channelId],
    @"bufferedAmount" : [NSNumber numberWithLongLong:channel.bufferedAmount],
    @"changedAmount" : [NSNumber numberWithLongLong:amount]
  }
      withChannel:channel];
}

@end
