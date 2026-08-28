#ifndef WEBRTC_BASE_HXX
#define WEBRTC_BASE_HXX

/* 对应 flutter_webrtc_base.h 的 FlutterWebRTCBase:
 * 持有 RTCPeerConnectionFactory + 系统音频专用 empty_adm_factory +
 * 音频/视频/桌面设备 + 本地流/轨道/capturer/data channel 注册表。
 * 初始化参考 flutter_webrtc_base.cc 构造函数。
 *
 * 【对齐说明】方法顺序与参数顺序尽量与 flutter_webrtc_base.h 保持一致, 便于对照 review。
 * 已补齐: PeerConnectionForId / RemovePeerConnectionForId / PeerConnectionObserversForId /
 *   RemovePeerConnectionObserversForId / GetRtpSenderById / GetRtpReceiverById / audio_processing()。
 * 以下属于 Flutter 渲染/纹理通道或 win/linux C ABI 不需要的, 省略并在注释标注(不占位):
 *   - event_channel() / renders_ / messenger_ / task_runner_ / textures_ (Flutter 通道/纹理渲染)
 *   - ParseConstraints(EncodableMap, RTCConfiguration*) (win/linux 用 ParseRTCConfiguration)
 *   - CreateIceServers (逻辑并入 ParseRTCConfiguration)
 *   - MediaTracksForId / RemoveTracksForId (复数轨道注册表别名, 本 port 用单数版)
 */
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "libwebrtc.h"
#include "rtc_audio_device.h"
#include "rtc_audio_processing.h"
#include "rtc_desktop_capturer.h"
#include "rtc_desktop_device.h"
#include "rtc_desktop_media_list.h"
#include "rtc_media_stream.h"
#include "rtc_mediaconstraints.h"
#include "rtc_peerconnection.h"
#include "rtc_video_device.h"

#include "webrtc_common.h"
#include "webrtc.h"

namespace webrtc {

using namespace libwebrtc;

class WebrtcMediaStream;
class WebrtcPeerConnection;
class WebrtcDataChannel;
class WebrtcDataChannelObserver;
class WebrtcScreenCapture;
class WebrtcFrameCryptor;
// PC 观察者(定义在 webrtc_peerconnection.h, 这里仅前向声明供注册表用裸指针)
class CppPcObserver;

class WebrtcBase {
 public:
  friend class WebrtcMediaStream;
  friend class WebrtcPeerConnection;
  friend class WebrtcDataChannel;
  friend class WebrtcScreenCapture;
  friend class WebrtcFrameCryptor;

 public:
  enum ParseConstraintType { kMandatory, kOptional };

 public:
  WebrtcBase();
  ~WebrtcBase();

  // LibWebRTC::Initialize + factory(含系统音频专用 empty_adm_factory) + 各设备
  // (flutter 在 ctor 里做, 这里拆成显式 Initialize 以便并发场景按需初始化)
  bool Initialize();

  scoped_refptr<RTCAudioProcessing> audio_processing() {
    return audio_processing_;
  }

  scoped_refptr<RTCMediaTrack> MediaTrackForId(const std::string& id);

  std::string GenerateUUID();  // Helper::CreateRandomUuid

  RTCPeerConnection* PeerConnectionForId(const std::string& id);

  void RemovePeerConnectionForId(const std::string& id);

  void RemoveMediaTrackForId(const std::string& id);

  CppPcObserver* PeerConnectionObserversForId(const std::string& id);

  void RemovePeerConnectionObserversForId(const std::string& id);

  scoped_refptr<RTCMediaStream> MediaStreamForId(const std::string& id);

  void RemoveStreamForId(const std::string& stream_id);

  // ---- RTCConfiguration / 媒体约束解析 ----
  // mandatory/optional → RTCMediaConstraints
  scoped_refptr<RTCMediaConstraints> ParseMediaConstraints(
      const JNode& constraints);

  // 解析 configuration 里 iceServers/iceTransportPolicy/bundlePolicy/
  // rtcpMuxPolicy/iceCandidatePoolSize/sdpSemantics/maxIPv6Networks
  void ParseRTCConfiguration(const JNode& map, RTCConfiguration& conf);

  // ---- MediaTracksForId / RemoveTracksForId / event_channel():
  //      flutter 专属(复数轨道别名 / Flutter 事件通道), 省略(见文件头注释) ----

  scoped_refptr<RTCRtpSender> GetRtpSenderById(RTCPeerConnection* pc,
                                               const std::string& id);
  scoped_refptr<RTCRtpReceiver> GetRtpReceiverById(RTCPeerConnection* pc,
                                                   const std::string& id);

  void lock() { mutex_.lock(); }
  void unlock() { mutex_.unlock(); }

 private:
  // 单个约束 map → RTCMediaConstraints(内部被 ParseMediaConstraints 调)
  void ParseConstraints(const JNode& src,
                        scoped_refptr<RTCMediaConstraints> media_constraints,
                        ParseConstraintType type = kMandatory);

 public:
  // factory 级事件回调(设备热插拔 onDeviceChange 等全局事件)
  webrtc_event_cb factory_event_cb_ = nullptr;
  void* factory_event_ud_ = nullptr;
  scoped_refptr<RTCPeerConnectionFactory> factory_;
  // 系统音频专用: is_myaudio=true, 不挂默认音频设备模块(同 flutter empty_adm_factory_)
  scoped_refptr<RTCPeerConnectionFactory> empty_adm_factory_;
  scoped_refptr<RTCAudioDevice> audio_device_;
  scoped_refptr<RTCVideoDevice> video_device_;
  // 桌面采集(始终包含, 原 RTC_DESKTOP_DEVICE 若宏已去掉)
  scoped_refptr<RTCDesktopDevice> desktop_device_;
  scoped_refptr<RTCDesktopCapturer> desktop_capturer_;
  // 桌面采集器影子表(锁屏帧替换要对**所有在跑的**桌面采集器生效):
  // key = **trackId**(uuid, 每路唯一 —— 一个 sourceId 可能建多个采集器, 不用源号作 key)。
  // 生命周期: MediaStreamDispose / MediaStreamTrackDispose 主动摘除(放掉引用, 采集线程随
  // source 销毁而停); SetExternalFrameCallback 遍历时也会以 local_tracks_ 为准兜底剔除
  // 其他 RemoveTrack 路径残留的条目。
  std::map<std::string, scoped_refptr<RTCDesktopCapturer>> desktop_capturers_;
  std::vector<scoped_refptr<MediaSource>> desktop_sources_;
  std::map<DesktopType, scoped_refptr<RTCDesktopMediaList>> desktop_medialist_;
  // 持久的屏幕采集对象(参考 flutter 的 FlutterScreenCapture 常驻):
  // 注册为 MediaListObserver 才能持续收到桌源增删/改名事件。
  std::unique_ptr<WebrtcScreenCapture> screen_capture_;
  // 持久的 E2EE 帧加密对象(参考 flutter_frame_cryptor 的 FlutterFrameCryptor 常驻):
  // 跨调用保存 frame_cryptors_ / key_providers_ 注册表。
  std::unique_ptr<WebrtcFrameCryptor> frame_cryptor_;
  scoped_refptr<RTCAudioProcessing> audio_processing_;
  // createPeerConnection 用的 RTCConfiguration(同 flutter configuration_)
  RTCConfiguration configuration_;

  // PC 按 peerConnectionId 持有(同 flutter peerconnections_); 由 pc 层 Create/Dispose 注册
  std::map<std::string, scoped_refptr<RTCPeerConnection>> peerconnections_;

  // 本地流按 streamId 持有(同 flutter local_streams_)
  std::map<std::string, scoped_refptr<RTCMediaStream>> local_streams_;
  // 本地轨道按 trackId 持有(同 flutter local_tracks_)
  std::map<std::string, scoped_refptr<RTCMediaTrack>> local_tracks_;
  // 视频 capturer 按 trackId 持有(同 flutter video_capturers_)
  std::map<std::string, scoped_refptr<RTCVideoCapturer>> video_capturers_;
  // data channel 观察者按 flutterId 持有(同 flutter data_channel_observers_)
  std::map<std::string, std::unique_ptr<WebrtcDataChannelObserver>>
      data_channel_observers_;
  // PC 观察者按 peerConnectionId 持有(同 flutter peerconnection_observers_, 裸指针,
  // 观察者对象生命周期归 PcHandle; 由 pc 层 Create/Dispose 注册/注销)
  std::map<std::string, CppPcObserver*> peerconnection_observers_;
  // renders_(视频渲染纹理) 省略(见文件头注释)

 private:
  // 供 lock()/unlock() 使用(flutter 用 mutable std::mutex, 这里保持非 mutable 亦可)
  std::mutex mutex_;
};

}  // namespace webrtc

#endif  // WEBRTC_BASE_HXX
