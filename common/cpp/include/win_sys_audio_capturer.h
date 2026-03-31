#ifndef WIN_SYS_AUDIO_CAPTURER_HXX
#define WIN_SYS_AUDIO_CAPTURER_HXX

//#if defined(_WIN32) || defined(WINDOWS)

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <endpointvolume.h>
#include <vector>
#include <string>
#include <thread>
#include <atomic>
#include <mutex>

#include "rtc_logging.h"

namespace flutter_webrtc_plugin {

class WinSysAudioCapturer {
 public:
  WinSysAudioCapturer();
  ~WinSysAudioCapturer();

  bool Initialize(const std::string& device_id = "");
  
  bool StartCapture();
  
  void StopCapture();
  
  void Release();

  using AudioDataCallback = void (*)(const void* audio_data,
                                     int bits_per_sample,
                                     int sample_rate,
                                     size_t number_of_channels,
                                     size_t number_of_frames,
                                     void* user_data);
  void SetCallback(AudioDataCallback callback, void* user_data);

  static std::vector<std::pair<std::string, std::string>> GetRecordingDevices();
  
  bool IsCapturing() const { return is_capturing_; }


  int preferred_sample_rate_ = 48000;      // 48kHz sample rate
  int preferred_bits_per_sample_ = 16;     // 16-bit depth
  int preferred_channels_ = 2;             // Stereo (2 channels)

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

};

}  // namespace flutter_webrtc_plugin

//#endif  // _WIN32

#endif  // WIN_SYS_AUDIO_CAPTURER_HXX
