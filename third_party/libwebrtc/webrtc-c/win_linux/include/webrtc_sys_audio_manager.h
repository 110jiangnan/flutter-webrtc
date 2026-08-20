#ifndef WEBRTC_SYS_AUDIO_MANAGER_HXX
#define WEBRTC_SYS_AUDIO_MANAGER_HXX

/* 对应 sys_audio_manager.h 的 SysAudioManager:
 * 全局单例, 管理系统音频采集源(WebrtcSysAudioSource),
 * 创建系统音频轨道/流(用 base 的 empty_adm_factory_)。 */
#include <map>
#include <mutex>
#include <string>

#include "libwebrtc.h"

#include "webrtc_base.h"
#include "webrtc_common.h"
#include "webrtc_sys_audio_source.h"

namespace webrtc {

using namespace libwebrtc;

class WebrtcSysAudioManager {
 public:
  static WebrtcSysAudioManager* GetInstance();

  static void DestroyInstance();

  bool Initialize(WebrtcBase* base, const std::string& device_id = "");

  // 创建系统音频流 + 轨道, 返回 {"streamId","ownerTag","audioTracks","videoTracks"}, 失败空串
  std::string GetSysAudioMedia(WebrtcBase* base, const std::string& stream_id);

  scoped_refptr<RTCAudioTrack> CreateSysAudioTrack(WebrtcBase* base,
                                                   const std::string& track_id = "");

  bool StartCapture();

  void StopCapture();

  bool IsCapturing() const { return is_capturing_; }

  bool IsInitialized() const { return is_initialized_; }

  std::string current_device_id() const { return current_device_id_; }

  // 与参考一致: 系统音频设备查询在 capturer 侧, 这里返回空
  std::map<std::string, std::string> GetRecordingDevices();

  // 切换设备需要重新初始化(参考 SwitchDevice)
  bool SwitchDevice(const std::string& device_id);

  void EnablePcmRecording(bool enable, const std::string& file_path);

  scoped_refptr<WebrtcSysAudioSource> GetAudioSource() { return audio_source_; }

  void Release();

 private:
  WebrtcSysAudioManager();
  ~WebrtcSysAudioManager();

  WebrtcSysAudioManager(const WebrtcSysAudioManager&) = delete;
  WebrtcSysAudioManager& operator=(const WebrtcSysAudioManager&) = delete;

  static WebrtcSysAudioManager* g_instance;
  static std::mutex g_mutex;

  scoped_refptr<WebrtcSysAudioSource> audio_source_;
  bool is_initialized_;
  bool is_capturing_;
  std::string current_device_id_;
};

}  // namespace webrtc

#endif  // WEBRTC_SYS_AUDIO_MANAGER_HXX
