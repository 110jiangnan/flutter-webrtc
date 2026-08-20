#ifndef WEBRTC_WIN_SYS_AUDIO_CAPTURER_HXX
#define WEBRTC_WIN_SYS_AUDIO_CAPTURER_HXX

/* 对应 win_sys_audio_capturer.h 的 WinSysAudioCapturer:
 * Windows WASAPI loopback 模式录制系统音频(扬声器输出), 非麦克风。
 * 数据经 AudioDataCallback 回调出去。 */

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace webrtc {

class WebrtcWinSysAudioCapturer {
 public:
  WebrtcWinSysAudioCapturer();
  ~WebrtcWinSysAudioCapturer();

  bool Initialize(const std::string& device_id = "");

  bool StartCapture();

  void StopCapture();

  void Release();

  using AudioDataCallback = void (*)(const void* audio_data,
                                     int bits_per_sample, int sample_rate,
                                     size_t number_of_channels,
                                     size_t number_of_frames, void* user_data);
  void SetCallback(AudioDataCallback callback, void* user_data);

  static std::vector<std::pair<std::string, std::string>>
  GetRecordingDevices();

  static bool IsSystemAudioCaptureSupported();

  bool IsCapturing() const { return is_capturing_; }

  int preferred_sample_rate_ = 48000;
  int preferred_bits_per_sample_ = 16;
  int preferred_channels_ = 2;

 private:
  void CaptureThread();

  bool InitializeWASAPI(const std::string& device_id);

  void CleanupCOM();

  IAudioClient* audio_client_ = nullptr;
  IAudioCaptureClient* capture_client_ = nullptr;
  IMMDeviceEnumerator* device_enumerator_ = nullptr;
  IMMDevice* device_ = nullptr;

  uint16_t _recChannelsPrioList[2] = {2, 1};
  WAVEFORMATEX* wave_format_ = nullptr;

  std::thread capture_thread_;
  std::atomic<bool> is_capturing_{false};
  std::atomic<bool> should_stop_{false};

  AudioDataCallback callback_ = nullptr;
  void* user_data_ = nullptr;

  mutable std::mutex mutex_;

  UINT32 buffer_frame_count_ = 0;
  DWORD flags_ = 0;
  bool com_initialized_ = false;  // 仅本对象成功初始化 COM 才在 Cleanup 里反初始化
};

}  // namespace webrtc

#endif  // WEBRTC_WIN_SYS_AUDIO_CAPTURER_HXX
