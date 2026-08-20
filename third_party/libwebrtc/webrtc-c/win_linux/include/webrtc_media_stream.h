#ifndef WEBRTC_MEDIA_STREAM_HXX
#define WEBRTC_MEDIA_STREAM_HXX

/* 对应 flutter_media_stream.h 的 FlutterMediaStream: getUserMedia 及本地流/轨道管理。
 * 实现按 flutter_media_stream.cc 的语义(被控=录制/采集端):
 *   采集   → getUserMedia(麦克风/摄像头)/ GetSources / SelectAudioInput / SelectAudioOutput
 *   本地流 → CreateLocalMediaStream / MediaStreamGetTracks / MediaStreamDispose
 *   轨道   → MediaStreamTrackSetEnable / MediaStreamTrackSwitchCamera / MediaStreamTrackDispose
 * 流和 capturer 由 WebrtcBase 注册表持有, 防止提前回收。 */
#include "webrtc_base.h"
#include "webrtc_common.h"

namespace webrtc {

class WebrtcMediaStream {
 public:
  explicit WebrtcMediaStream(WebrtcBase* base);

  // media_constraints: {"audio":true|{...},"video":true|{...}}
  // 返回 {"streamId":"..","audioTracks":[...],"videoTracks":[...]}, 失败返回空串
  std::string GetUserMedia(const JNode& constraints);

  // 从 audio/video 约束采集单条轨道(同 flutter GetUserAudio/GetUserVideo 为 public),
  // 成功把轨道 JSON 写入 out
  bool GetUserAudio(const JNode& audio, RTCMediaStream* stream, JNode* out);
  bool GetUserVideo(const JNode& video, RTCMediaStream* stream, JNode* out);

  // 枚举采集设备 {"sources":[{"label","deviceId","facing","kind"}...]}
  std::string GetSources();

  // 选择播放/录音设备, 找到并设置返回 true
  bool SelectAudioOutput(const std::string& device_id);
  bool SelectAudioInput(const std::string& device_id);

  // 取流的轨道列表 {"audioTracks":[...],"videoTracks":[...]}, 流不存在返回空串
  std::string MediaStreamGetTracks(const std::string& stream_id);

  // 释放本地流: 移除全部轨道、停掉 capturer、清注册表
  void MediaStreamDispose(const std::string& stream_id);

  // 开/关轨道(enabled), 成功返回 true
  bool MediaStreamTrackSetEnable(const std::string& track_id, bool enable);

  // 设置音频轨道音量(0.0~1.0, setVolume), 只对 audio 轨道生效
  bool MediaStreamTrackSetVolume(const std::string& track_id, double volume);

  // 切换摄像头(移动端专用, 桌面无对应 API, 同 flutter NotImplemented)
  void MediaStreamTrackSwitchCamera(const std::string& track_id);

  // 释放单个轨道: 从所有本地流移除、停掉视频 capturer
  void MediaStreamTrackDispose(const std::string& track_id);

  // 创建空本地流, 返回 {"streamId":uuid}, 失败返回空串
  std::string CreateLocalMediaStream();

  // 采集设备热插拔回调注册(同 flutter 构造时注册; 事件面接 dart 后续补)
  void OnDeviceChange();

  // 本 port 扩展(flutter 在 method channel 层直接做): 往流里加/移除轨道
  bool MediaStreamAddTrack(const std::string& stream_id,
                           const std::string& track_id);
  bool MediaStreamRemoveTrack(const std::string& stream_id,
                              const std::string& track_id);

 private:
  WebrtcBase* base_;
};

}  // namespace webrtc

#endif  // WEBRTC_MEDIA_STREAM_HXX
