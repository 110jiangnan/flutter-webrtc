#ifndef WEBRTC_BASE_HXX
#define WEBRTC_BASE_HXX

/* 对应 flutter_webrtc_base.h 的 FlutterWebRTCBase:
 * 持有 RTCPeerConnectionFactory + 系统音频专用 empty_adm_factory +
 * 音频/视频/桌面设备 + 本地流/轨道/capturer/data channel 注册表。
 * 初始化参考 flutter_webrtc_base.cc 构造函数。 */
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "libwebrtc.h"
#include "rtc_audio_device.h"
#include "rtc_audio_processing.h"
#include "rtc_media_stream.h"
#include "rtc_mediaconstraints.h"
#include "rtc_video_device.h"
#ifdef RTC_DESKTOP_DEVICE
#include "rtc_desktop_capturer.h"
#include "rtc_desktop_device.h"
#include "rtc_desktop_media_list.h"
#endif

#include "webrtc_common.h"

namespace webrtc {

using namespace libwebrtc;

class WebrtcMediaStream;
class WebrtcPeerConnection;
class WebrtcDataChannel;
class WebrtcDataChannelObserver;
class WebrtcScreenCapture;

class WebrtcBase {
 public:
  friend class WebrtcMediaStream;
  friend class WebrtcPeerConnection;
  friend class WebrtcDataChannel;
  friend class WebrtcScreenCapture;

 public:
  WebrtcBase();
  ~WebrtcBase();

  // LibWebRTC::Initialize + factory(含系统音频专用 empty_adm_factory) + 各设备
  bool Initialize();

  std::string GenerateUUID();  // Helper::CreateRandomUuid

  // ---- RTCConfiguration / 媒体约束解析(参考 flutter_webrtc_base.cc) ----
  enum ParseConstraintType { kMandatory, kOptional };

  // 解析 configuration 里 iceServers/iceTransportPolicy/bundlePolicy/
  // rtcpMuxPolicy/iceCandidatePoolSize/sdpSemantics/maxIPv6Networks
  void ParseRTCConfiguration(const JNode& map, RTCConfiguration& conf);
  // mandatory/optional → RTCMediaConstraints
  scoped_refptr<RTCMediaConstraints> ParseMediaConstraints(
      const JNode& constraints);

  // 按 streamId / trackId 查找本地对象(被控 addTrack/setTrack 等按 id 引用)
  scoped_refptr<RTCMediaStream> MediaStreamForId(const std::string& id);
  scoped_refptr<RTCMediaTrack> MediaTrackForId(const std::string& id);
  void RemoveMediaTrackForId(const std::string& id);

  // 按 streamId 释放本地流, 并顺带清掉该流视频轨道对应的 capturer
  void RemoveStreamForId(const std::string& stream_id);

  void lock() { mutex_.lock(); }
  void unlock() { mutex_.unlock(); }

 public:
  scoped_refptr<RTCPeerConnectionFactory> factory_;
  // 系统音频专用: is_myaudio=true, 不挂默认音频设备模块(同 flutter empty_adm_factory_)
  scoped_refptr<RTCPeerConnectionFactory> empty_adm_factory_;
  scoped_refptr<RTCAudioDevice> audio_device_;
  scoped_refptr<RTCVideoDevice> video_device_;
#ifdef RTC_DESKTOP_DEVICE
  scoped_refptr<RTCDesktopDevice> desktop_device_;
  // 屏幕采集状态(同 flutter base.desktop_capturer_ + screen_capture 的源列表)
  scoped_refptr<RTCDesktopCapturer> desktop_capturer_;
  std::vector<scoped_refptr<MediaSource>> desktop_sources_;
  std::map<DesktopType, scoped_refptr<RTCDesktopMediaList>> desktop_medialist_;
#endif
  scoped_refptr<RTCAudioProcessing> audio_processing_;
  // createPeerConnection 用的 RTCConfiguration(同 flutter configuration_)
  RTCConfiguration configuration_;

  // 本地流按 streamId 持有(同 flutter local_streams_)
  std::map<std::string, scoped_refptr<RTCMediaStream>> local_streams_;
  // 本地轨道按 trackId 持有(同 flutter local_tracks_)
  std::map<std::string, scoped_refptr<RTCMediaTrack>> local_tracks_;
  // 视频 capturer 按 trackId 持有(同 flutter video_capturers_)
  std::map<std::string, scoped_refptr<RTCVideoCapturer>> video_capturers_;
  // data channel 观察者按 flutterId 持有(同 flutter data_channel_observers_)
  std::map<std::string, std::unique_ptr<WebrtcDataChannelObserver>>
      data_channel_observers_;

 private:
  // 单个约束 map → RTCMediaConstraints(内部被 ParseMediaConstraints 调)
  void ParseConstraints(const JNode& src,
                        scoped_refptr<RTCMediaConstraints> media_constraints,
                        ParseConstraintType type = kMandatory);

  std::mutex mutex_;
};

}  // namespace webrtc

#endif  // WEBRTC_BASE_HXX
