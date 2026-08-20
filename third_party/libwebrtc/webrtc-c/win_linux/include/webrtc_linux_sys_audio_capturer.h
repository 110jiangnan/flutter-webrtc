#ifndef WEBRTC_LINUX_SYS_AUDIO_CAPTURER_HXX
#define WEBRTC_LINUX_SYS_AUDIO_CAPTURER_HXX

/* 对应 linux_sys_audio_capturer.h 的 LinuxSysAudioCapturer:
 * PulseAudio Monitor 源录制系统音频(仅 Linux, 需 libpulse-simple)。 */

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace webrtc {

class WebrtcLinuxSysAudioCapturer {
 public:
  WebrtcLinuxSysAudioCapturer();
  ~WebrtcLinuxSysAudioCapturer();

  bool Initialize(const std::string& device_id = "");

  bool StartCapture();

  void StopCapture();

  void Release();

  using AudioDataCallback = void (*)(const void* audio_data,
                                     int bits_per_sample, int sample_rate,
                                     size_t number_of_channels,
                                     size_t number_of_frames, void* user_data);
  void SetCallback(AudioDataCallback callback, void* user_data);

  // 仅返回 Monitor 源(系统音频输出设备)
  static std::vector<std::pair<std::string, std::string>>
  GetRecordingDevices();

  static bool IsSystemAudioCaptureSupported();

  bool IsCapturing() const { return is_capturing_; }

  int preferred_sample_rate_ = 48000;
  int sample_rate_ = 48000;
  int channels_ = 2;
  int bits_per_sample_ = 16;

 private:
  bool InitializePulseAudio(const std::string& device_id);
  void CleanupPulseAudio();
  void CaptureThread();

  void* pulse_stream_ = nullptr;  // pa_simple*

  std::thread capture_thread_;
  std::atomic<bool> is_capturing_{false};
  std::atomic<bool> should_stop_{false};

  AudioDataCallback callback_ = nullptr;
  void* user_data_ = nullptr;
  mutable std::mutex mutex_;
};

}  // namespace webrtc

#endif  // WEBRTC_LINUX_SYS_AUDIO_CAPTURER_HXX
