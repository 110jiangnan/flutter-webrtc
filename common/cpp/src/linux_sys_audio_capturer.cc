// Linux 系统音频捕获器实现
// 使用 PulseAudio 录制系统音频（需要 libpulse-simple）
// 注意：仅录制 Monitor 源（系统音频输出），不录制麦克风

//#if defined(__linux__) || defined(LINUX)

#include "linux_sys_audio_capturer.h"

// 尝试包含 PulseAudio，如果不可用则使用占位实现
#ifdef HAVE_PULSEAUDIO
#include <pulse/pulseaudio.h>
#include <pulse/glib-mainloop.h>
#include <cstring>
#endif

namespace flutter_webrtc_plugin {

#ifdef HAVE_PULSEAUDIO
// 全局变量用于存储 Sink 列表查询结果
struct SinkInfoData {
  std::vector<std::pair<std::string, std::string>>* devices;
  bool done;
};

// Sink 信息回调函数（查询 Monitor 源）
void sink_info_callback(pa_context* context,
                        const pa_sink_info* info,
                        int eol,
                        void* userdata) {
  if (eol < 0) {
    return;  // 错误
  }
  
  if (eol == 1) {
    // 查询结束
    SinkInfoData* data = static_cast<SinkInfoData*>(userdata);
    data->done = true;
    return;
  }
  
  // 跳过无效或悬空的 Sink
  if (!info || !info->name) {
    return;
  }
  
  // 构造 Monitor 源名称：<sink_name>.monitor
  std::string monitor_name = std::string(info->name) + ".monitor";
  std::string description = info->description ? 
                            std::string(info->description) + " (Monitor)" : 
                            monitor_name;
  
  SinkInfoData* data = static_cast<SinkInfoData*>(userdata);
  data->devices->push_back({monitor_name, description});
}
#endif

LinuxSysAudioCapturer::LinuxSysAudioCapturer() {
#ifdef HAVE_PULSEAUDIO
  RTC_LOG(LS_INFO) << "LinuxSysAudioCapturer created (PulseAudio mode)";
#else
  RTC_LOG(LS_INFO) << "LinuxSysAudioCapturer created (stub mode - PulseAudio not available)";
#endif
}

LinuxSysAudioCapturer::~LinuxSysAudioCapturer() {
  StopCapture();
  Release();
  RTC_LOG(LS_INFO) << "LinuxSysAudioCapturer destroyed";
}

bool LinuxSysAudioCapturer::Initialize(const std::string& device_id) {
#ifdef HAVE_PULSEAUDIO
  return InitializePulseAudio(device_id);
#else
  // 占位模式：返回失败但不崩溃
  RTC_LOG(LS_WARNING) 
      << "LinuxSysAudioCapturer::Initialize() - PulseAudio not available, returning false";
  return false;
#endif
}

bool LinuxSysAudioCapturer::StartCapture() {
#ifdef HAVE_PULSEAUDIO
  if (!pulse_stream_) {
    RTC_LOG(LS_ERROR) << "Cannot start capture - PulseAudio not initialized";
    return false;
  }
  
  if (is_capturing_) {
    RTC_LOG(LS_WARNING) << "Already capturing";
    return false;
  }

  should_stop_ = false;
  is_capturing_ = true;
  
  // 启动捕获线程
  capture_thread_ = std::thread(&LinuxSysAudioCapturer::CaptureThread, this);
  
  RTC_LOG(LS_INFO) << "Started PulseAudio capture";
  return true;
#else
  // 占位模式：返回失败但不崩溃
  RTC_LOG(LS_WARNING) 
      << "LinuxSysAudioCapturer::StartCapture() - PulseAudio not available, returning false";
  return false;
#endif
}

void LinuxSysAudioCapturer::StopCapture() {
  if (!is_capturing_) {
    return;
  }

  should_stop_ = true;
  is_capturing_ = false;

  // 等待捕获线程结束
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }

  RTC_LOG(LS_INFO) << "Stopped audio capture";
}

void LinuxSysAudioCapturer::Release() {
#ifdef HAVE_PULSEAUDIO
  CleanupPulseAudio();
#endif
  RTC_LOG(LS_VERBOSE) << "LinuxSysAudioCapturer::Release()";
}

void LinuxSysAudioCapturer::SetCallback(AudioDataCallback callback, void* user_data) {
  std::lock_guard<std::mutex> lock(mutex_);
  callback_ = callback;
  user_data_ = user_data;
  RTC_LOG(LS_VERBOSE) << "LinuxSysAudioCapturer::SetCallback()";
}

std::vector<std::pair<std::string, std::string>> 
LinuxSysAudioCapturer::GetRecordingDevices() {
#ifdef HAVE_PULSEAUDIO
  std::vector<std::pair<std::string, std::string>> devices;
  
  // 创建主循环和上下文
  pa_mainloop* mainloop = pa_mainloop_new();
  if (!mainloop) {
    RTC_LOG(LS_ERROR) << "Failed to create PulseAudio mainloop";
    return devices;
  }
  
  pa_context* context = pa_context_new(pa_mainloop_get_api(mainloop), "sys_audio_devices");
  if (!context) {
    pa_mainloop_free(mainloop);
    return devices;
  }
  
  // 连接到 PulseAudio 服务器
  if (pa_context_connect(context, nullptr, PA_CONTEXT_NOFAIL, nullptr) < 0) {
    pa_context_unref(context);
    pa_mainloop_free(mainloop);
    return devices;
  }
  
  // 等待连接就绪
  pa_context_state_t state;
  while ((state = pa_context_get_state(context)) != PA_CONTEXT_READY) {
    if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
      RTC_LOG(LS_ERROR) << "PulseAudio context failed to connect";
      pa_context_unref(context);
      pa_mainloop_free(mainloop);
      return devices;
    }
    
    pa_mainloop_iterate(mainloop, 1, nullptr);
  }
  
  // 准备查询 Sink 列表
  SinkInfoData data;
  data.devices = &devices;
  data.done = false;
  
  // 异步查询所有 Sink 信息（输出设备）
  pa_operation* op = pa_context_get_sink_info_list(context, sink_info_callback, &data);
  if (!op) {
    RTC_LOG(LS_ERROR) << "Failed to get sink info list";
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_mainloop_free(mainloop);
    return devices;
  }
  
  // 等待查询完成
  while (!data.done) {
    pa_mainloop_iterate(mainloop, 1, nullptr);
  }
  
  pa_operation_unref(op);
  
  // 如果没有找到任何 Monitor 源，添加一个默认的
  if (devices.empty()) {
    RTC_LOG(LS_WARNING) << "No monitor sources found, adding default";
    devices.push_back({"default", "Default Audio Device"});
  }
  
  // 断开连接并清理
  pa_context_disconnect(context);
  pa_context_unref(context);
  pa_mainloop_free(mainloop);
  
  RTC_LOG(LS_INFO) << "Found " << devices.size() << " monitor sources";
  for (const auto& device : devices) {
    RTC_LOG(LS_INFO) << "  - " << device.second << " (" << device.first << ")";
  }
  
  return devices;
#else
  // 占位模式：返回空列表
  RTC_LOG(LS_INFO) 
      << "LinuxSysAudioCapturer::GetRecordingDevices() - Returning empty list (PulseAudio not available)";
  return std::vector<std::pair<std::string, std::string>>();
#endif
}

#ifdef HAVE_PULSEAUDIO
bool LinuxSysAudioCapturer::InitializePulseAudio(const std::string& device_id) {
  // 设置音频格式
  sample_spec_.format = PA_SAMPLE_S16LE;  // 16-bit little-endian
  sample_spec_.rate = sample_rate_;
  sample_spec_.channels = channels_;

  // 创建 PulseAudio 简单流
  int error;
  pulse_stream_ = pa_simple_new(
      nullptr,                                    // 使用默认服务器
      "System Audio Capture",                     // 应用名称
      PA_STREAM_RECORD,                           // 录制模式
      device_id.empty() ? nullptr : device_id.c_str(),  // 设备 ID
      "Record",                                   // 流描述
      &sample_spec_,                              // 采样格式
      nullptr,                                    // 使用默认通道映射
      nullptr,                                    // 缓冲属性（使用默认）
      &error                                      // 错误代码
  );

  if (!pulse_stream_) {
    RTC_LOG(LS_ERROR) << "Failed to create PulseAudio stream: " 
                      << pa_strerror(error);
    return false;
  }

  RTC_LOG(LS_INFO) << "PulseAudio initialized successfully";
  RTC_LOG(LS_INFO) << "Sample rate: " << sample_spec_.rate 
                   << ", Channels: " << sample_spec_.channels
                   << ", Format: S16LE";
  
  return true;
}

void LinuxSysAudioCapturer::CleanupPulseAudio() {
  if (pulse_stream_) {
    pa_simple_free(pulse_stream_);
    pulse_stream_ = nullptr;
    RTC_LOG(LS_INFO) << "PulseAudio stream cleaned up";
  }
}

void LinuxSysAudioCapturer::CaptureThread() {
  RTC_LOG(LS_INFO) << "PulseAudio capture thread started";
  
  // 缓冲区大小（根据采样率和帧数计算）
  const size_t frames_per_buffer = 480;  // 10ms @ 48kHz
  const size_t bytes_per_frame = channels_ * (bits_per_sample_ / 8);
  const size_t buffer_size = frames_per_buffer * bytes_per_frame;
  
  std::vector<uint8_t> buffer(buffer_size);
  
  while (!should_stop_) {
    int error;
    
    // 从 PulseAudio 读取数据
    if (pa_simple_read(pulse_stream_, buffer.data(), buffer_size, &error) < 0) {
      RTC_LOG(LS_ERROR) << "Failed to read from PulseAudio: " 
                        << pa_strerror(error);
      break;
    }
    
    // 调用回调传递音频数据
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (callback_) {
        callback_(buffer.data(),
                  bits_per_sample_,
                  sample_rate_,
                  channels_,
                  frames_per_buffer,
                  user_data_);
      }
    }
  }
  
  RTC_LOG(LS_INFO) << "PulseAudio capture thread stopped";
}
#endif  // HAVE_PULSEAUDIO

}  // namespace flutter_webrtc_plugin

//#endif  // __linux__
