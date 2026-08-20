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

  // 方法声明顺序对齐 flutter_peerconnection.h 的 FlutterPeerConnection:
  //   Create ↔ CreateRTCPeerConnection, Close ↔ RTCPeerConnectionClose,
  //   Dispose ↔ RTCPeerConnectionDispose, 其余方法名一一对应。
  // CaptureFrame 需独立渲染模块, 按需求排除。

  // ---- 建连(CreateRTCPeerConnection) ----
  // 解析 configuration/constraints, 建 PC 并注册观察者; 返回句柄, 失败 NULL
  webrtc_handle Create(const JNode& configuration, const JNode& constraints,
                       webrtc_event_cb on_event, void* user_data);

  // ---- RTCPeerConnectionClose / RTCPeerConnectionDispose ----
  // 关闭连接(句柄仍有效, 还能收事件)
  static void Close(webrtc_handle pc);
  // 彻底释放(注销观察者 + 删除句柄)
  static void Dispose(webrtc_handle pc);

  // ---- CreateOffer ----
  void CreateOffer(const JNode& constraints, webrtc_handle pc,
                   webrtc_result_cb cb, void* ud);

  // ---- CreateAnswer ----
  void CreateAnswer(const JNode& constraints, webrtc_handle pc,
                    webrtc_result_cb cb, void* ud);

  // ---- SetLocalDescription / SetRemoteDescription ----
  void SetLocalDescription(const char* sdp, const char* type, webrtc_handle pc,
                           webrtc_result_cb cb, void* ud);
  void SetRemoteDescription(const char* sdp, const char* type,
                            webrtc_handle pc, webrtc_result_cb cb, void* ud);

  // ---- GetLocalDescription / GetRemoteDescription ----
  void GetLocalDescription(webrtc_handle pc, webrtc_result_cb cb, void* ud);
  void GetRemoteDescription(webrtc_handle pc, webrtc_result_cb cb, void* ud);

  // ---- AddTransceiver(参考的 mapToRtpTransceiverInit/stringToTransceiverDirection/
  //      mapToEncoding 辅助已做成匿名函数, 定义在 webrtc_peerconnection.cc) ----
  // track_id 非空走 track 重载, 否则按 media_type; init_json 可空。
  char* AddTransceiver(webrtc_handle pc, const char* track_id,
                       const char* media_type, const char* init_json);

  // ---- GetTransceivers ----
  char* GetTransceivers(webrtc_handle pc);

  // ---- GetReceivers ----
  char* GetReceivers(webrtc_handle pc);

  // ---- RtpSenderSetTrack(含 RtpSenderReplaceTrack: 参考二者都走 set_track) ----
  void RtpSenderSetTrack(webrtc_handle pc, const char* sender_id,
                         const char* track_id, webrtc_result_cb cb, void* ud);

  // ---- RtpSenderSetStream ----
  void RtpSenderSetStream(webrtc_handle pc, const char* sender_id,
                          const char* stream_ids_json, webrtc_result_cb cb,
                          void* ud);

  // ---- RtpSenderSetParameters ----
  char* RtpSenderSetParameters(webrtc_handle pc, const char* sender_id,
                               const char* params_json);

  // ---- RtpTransceiverStop ----
  void RtpTransceiverStop(webrtc_handle pc, const char* transceiver_id,
                          webrtc_result_cb cb, void* ud);

  // ---- RtpTransceiverGetCurrentDirection ----
  void RtpTransceiverGetCurrentDirection(webrtc_handle pc,
                                         const char* transceiver_id,
                                         webrtc_result_cb cb, void* ud);

  // ---- SetConfiguration(参考实现本身即 TODO, 这里仅成功返回) ----
  void SetConfiguration(webrtc_handle pc, const char* configuration_json,
                        webrtc_result_cb cb, void* ud);

  // ---- RtpTransceiverSetDirection ----
  void RtpTransceiverSetDirection(webrtc_handle pc, const char* transceiver_id,
                                  const char* direction, webrtc_result_cb cb,
                                  void* ud);

  // ---- RtpTransceiverSetCodecPreferences ----
  void RtpTransceiverSetCodecPreferences(webrtc_handle pc,
                                         const char* transceiver_id,
                                         const char* codecs_json);

  // ---- GetSenders ----
  char* GetSenders(webrtc_handle pc);

  // ---- AddIceCandidate ----
  int AddIceCandidate(webrtc_handle pc, const char* candidate_json);

  // ---- GetStats ----
  void GetStats(webrtc_handle pc, const char* track_id, webrtc_result_cb cb,
                void* ud);

  // ---- 补充(对齐 flutter_webrtc.cc 的 addStream/removeStream/restartIce/
  //      DTMF/状态同步查询) ----
  // addStream/removeStream: 把本地流挂到/摘离 pc, 返回 0 成功
  int AddStream(webrtc_handle pc, const char* stream_id);
  int RemoveStream(webrtc_handle pc, const char* stream_id);
  // restartIce: 重启 ICE(参考 pc->RestartIce)
  void RestartIce(webrtc_handle pc);
  // DTMF: 按 senderId 查 dtmf_sender, 分别取能否插入 / 插入; 返回 1 成功
  int RtpSenderCanInsertDtmf(webrtc_handle pc, const char* sender_id);
  int RtpSenderInsertDtmf(webrtc_handle pc, const char* sender_id,
                          const char* tones, int duration, int gap);
  // 状态同步查询: 返回 "state" JSON 字符串({state:"..."}), 失败 ""。
  // 分别对应用户可见的信令/ICE收集/ICE连接/整体连接状态。
  // (dart 侧一般已由事件缓存状态, 这里补同步查询与 flutter 对等)
  char* GetSignalingState(webrtc_handle pc);
  char* GetIceGatheringState(webrtc_handle pc);
  char* GetIceConnectionState(webrtc_handle pc);
  char* GetConnectionState(webrtc_handle pc);

  // ---- AddTrack / RemoveTrack ----
  // 把本地轨 addTrack 到 pc, 返回 sender 的 JSON(rtpSenderToMap), 失败 NULL
  char* AddTrack(webrtc_handle pc, const char* track_id, const char* stream_id);
  // 按 senderId 移除发送轨道, 返回 {"result":bool}
  char* RemoveTrack(webrtc_handle pc, const char* sender_id);

 private:
  WebrtcBase* base_;
};

}  // namespace webrtc

#endif  // WEBRTC_PEERCONNECTION_HXX
