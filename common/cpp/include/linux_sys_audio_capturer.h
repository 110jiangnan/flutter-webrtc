#ifndef LINUX_SYS_AUDIO_CAPTURER_HXX
#define LINUX_SYS_AUDIO_CAPTURER_HXX

// 仅 Linux 平台
#if defined(__linux__) || defined(LINUX)

#include <string>
#include <vector>
#include <atomic>
#include <mutex>
#include <thread>

// PulseAudio 头文件
#include <pulse/pulseaudio.h>
#include <pulse/simple.h>
#include <pulse/error.h>

namespace flutter_webrtc_plugin {

/**
 * Linux 系统音频捕获器
 * 
 * 支持两种模式：
 * 1. PulseAudio 模式（推荐）：使用 libpulse-simple 录制系统音频（Monitor 源）
 * 2. 占位模式：当 PulseAudio 不可用时，返回失败
 * 
 * 注意：所有方法都有返回值，不会崩溃
 */
class LinuxSysAudioCapturer {
 public:
  LinuxSysAudioCapturer();
  ~LinuxSysAudioCapturer();

  // 初始化音频捕获设备
  bool Initialize(const std::string& device_id = "");
  
  // 开始捕获音频
  bool StartCapture();
  
  // 停止捕获音频
  void StopCapture();
  
  // 释放资源
  void Release();

  // 设置音频数据回调
  using AudioDataCallback = void (*)(const void* audio_data,
                                     int bits_per_sample,
                                     int sample_rate,
                                     size_t number_of_channels,
                                     size_t number_of_frames,
                                     void* user_data);
  void SetCallback(AudioDataCallback callback, void* user_data);

  // 获取录音设备列表（仅返回 Monitor 源/系统音频输出设备）
  static std::vector<std::pair<std::string, std::string>> GetRecordingDevices();
  
  // 检查是否支持系统音频捕获
  static bool IsSystemAudioCaptureSupported();
  
  // 检查是否正在捕获
  bool IsCapturing() const { return is_capturing_; }

 private:
  // PulseAudio 相关成员
  bool InitializePulseAudio(const std::string& device_id);
  void CleanupPulseAudio();
  void CaptureThread();
  
  // PulseAudio 流对象
  pa_simple* pulse_stream_ = nullptr;
  pa_sample_spec sample_spec_;

  // 线程和资源管理
  std::thread capture_thread_;
  std::atomic<bool> is_capturing_{false};
  std::atomic<bool> should_stop_{false};
  
  // 回调相关
  AudioDataCallback callback_ = nullptr;
  void* user_data_ = nullptr;
  mutable std::mutex mutex_;

public:
  // 音频参数
  int preferred_sample_rate_ = 48000;
  int sample_rate_ = 48000;      // 采样率：48kHz
  int channels_ = 2;             // 声道数：立体声
  int bits_per_sample_ = 16;     // 位深：16-bit
};

}  // namespace flutter_webrtc_plugin

#endif  // __linux__

#endif  // LINUX_SYS_AUDIO_CAPTURER_HXX
