#ifndef WEBRTC_PEERCONNECTION_HXX
#define WEBRTC_PEERCONNECTION_HXX

/* 对应 flutter_peerconnection.h 的 FlutterPeerConnectionObserver + FlutterPeerConnection。
 * 只实现"被控=录制/发送端"需要的方法:
 *   建连   → Create / Close / Dispose
 *   answer → CreateAnswer / SetLocalDescription / SetRemoteDescription
 *   ICE    → AddIceCandidate
 *   发送   → AddTrack / RemoveTrack / GetSenders / GetTransceivers /
 *             RtpSenderSetParameters / RtpTransceiverSetCodecPreferences / GetStats
 * 观察者把 libwebrtc 事件组装成 JSON, 经 C 回调转发给 dart。
 * 事件在 webrtc signaling 线程触发, 回调必须能跨线程(dart 用 NativeCallable.listener)。 */
#include "webrtc.h"

#include "rtc_data_channel.h"
#include "rtc_peerconnection.h"

#include "webrtc_base.h"
#include "webrtc_common.h"

namespace webrtc {

using namespace libwebrtc;

// 观察者: 把 libwebrtc 事件转成 JSON 回调给 dart
class CppPcObserver : public RTCPeerConnectionObserver {
 public:
  webrtc_event_cb cb_ = nullptr;
  void* ud_ = nullptr;
  WebrtcBase* base_ = nullptr;  // 供 OnDataChannel 把观察者存进注册表

  void Fire(const std::string& event, const JNode& body);

  void OnIceCandidate(scoped_refptr<RTCIceCandidate> candidate) override;
  void OnIceConnectionState(RTCIceConnectionState state) override;
  void OnPeerConnectionState(RTCPeerConnectionState state) override;
  void OnIceGatheringState(RTCIceGatheringState state) override;
  void OnSignalingState(RTCSignalingState state) override;
  void OnTrack(scoped_refptr<RTCRtpTransceiver> transceiver) override;
  void OnAddTrack(vector<scoped_refptr<RTCMediaStream>> streams,
                  scoped_refptr<RTCRtpReceiver> receiver) override;
  void OnRemoveTrack(scoped_refptr<RTCRtpReceiver> receiver) override;
  void OnAddStream(scoped_refptr<RTCMediaStream> stream) override;
  void OnRemoveStream(scoped_refptr<RTCMediaStream> stream) override;
  void OnDataChannel(scoped_refptr<RTCDataChannel> data_channel) override;
  void OnRenegotiationNeeded() override;

  // 远端流/轨按 id 查找(同 FlutterPeerConnectionObserver)
  scoped_refptr<RTCMediaStream> MediaStreamForId(const std::string& id);
  scoped_refptr<RTCMediaTrack> MediaTrackForId(const std::string& id);
  void RemoveStreamForId(const std::string& id);

 private:
  std::map<std::string, scoped_refptr<RTCMediaStream>> remote_streams_;
};

// PC 不透明句柄: dart 持有, 内部是 PC + 观察者 + base
struct PcHandle {
  WebrtcBase* base = nullptr;      // 供 AddTrack/GetStats 等按 id 查 track
  CppPcObserver observer;          // 声明在 pc 前 → 析构时 pc 先销毁, 观察者活得比 pc 久
  scoped_refptr<RTCPeerConnection> pc;
};

class WebrtcPeerConnection {
 public:
  explicit WebrtcPeerConnection(WebrtcBase* base);

  // 解析 configuration/constraints, 建 PC 并注册观察者; 返回句柄, 失败 NULL
  webrtc_handle Create(const JNode& configuration, const JNode& constraints,
                       webrtc_event_cb on_event, void* user_data);

  // ---- 被控: answer 流程(异步, 结果走回调) ----
  void CreateAnswer(const JNode& constraints, webrtc_handle pc,
                    webrtc_result_cb cb, void* ud);
  void SetLocalDescription(const char* sdp, const char* type, webrtc_handle pc,
                           webrtc_result_cb cb, void* ud);
  void SetRemoteDescription(const char* sdp, const char* type,
                            webrtc_handle pc, webrtc_result_cb cb, void* ud);

  // ---- 被控: ICE ----
  int AddIceCandidate(webrtc_handle pc, const char* candidate_json);

  // ---- 被控: 发送媒体 ----
  // 把本地轨 addTrack 到 pc, 返回 sender 的 JSON(rtpSenderToMap), 失败 NULL
  char* AddTrack(webrtc_handle pc, const char* track_id, const char* stream_id);
  // 按 senderId 移除发送轨道, 返回 {"result":bool}
  char* RemoveTrack(webrtc_handle pc, const char* sender_id);
  // 返回 {"senders":[...]} / {"transceivers":[...]}
  char* GetSenders(webrtc_handle pc);
  char* GetTransceivers(webrtc_handle pc);
  // 设置 sender 的编码参数(码率/帧率等), 返回 {"result":bool}
  char* RtpSenderSetParameters(webrtc_handle pc, const char* sender_id,
                               const char* params_json);
  // 设置 transceiver 的编码偏好(setPreferredCodecs)
  void RtpTransceiverSetCodecPreferences(webrtc_handle pc,
                                         const char* transceiver_id,
                                         const char* codecs_json);
  // 取统计信息(异步, 结果走回调)
  void GetStats(webrtc_handle pc, const char* track_id, webrtc_result_cb cb,
                void* ud);

  // ---- 生命周期 ----
  // 关闭连接(句柄仍有效, 还能收事件)
  static void Close(webrtc_handle pc);
  // 彻底释放(注销观察者 + 删除句柄)
  static void Dispose(webrtc_handle pc);

 private:
  WebrtcBase* base_;
};

}  // namespace webrtc

#endif  // WEBRTC_PEERCONNECTION_HXX
