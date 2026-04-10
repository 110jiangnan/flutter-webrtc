// Linux 系统音频捕获器实现
// 使用 PulseAudio 录制系统音频(需要 libpulse-simple)
// 注意:仅录制 Monitor 源(系统音频输出),不录制麦克风

// #if defined(__linux__) || defined(LINUX)

#include "linux_sys_audio_capturer.h"
#include <iostream>

#include <pulse/pulseaudio.h>
#include <pulse/glib-mainloop.h>
#include <cstring>

namespace flutter_webrtc_plugin {

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

LinuxSysAudioCapturer::LinuxSysAudioCapturer() {

}

LinuxSysAudioCapturer::~LinuxSysAudioCapturer() {
  StopCapture();
  Release();
  std::cout << "INFO: LinuxSysAudioCapturer destroyed" << std::endl;
}

bool LinuxSysAudioCapturer::Initialize(const std::string& device_id) {
  return InitializePulseAudio(device_id);
}

bool LinuxSysAudioCapturer::StartCapture() {
  if (!pulse_stream_) {
    std::cerr << "ERROR: Cannot start capture - PulseAudio not initialized" << std::endl;
    return false;
  }
  
  if (is_capturing_) {
    std::cerr << "WARNING: Already capturing" << std::endl;
    return true;
  }

  should_stop_ = false;
  is_capturing_ = true;
  
  // 启动捕获线程
  capture_thread_ = std::thread(&LinuxSysAudioCapturer::CaptureThread, this);
  
  std::cout << "INFO: Started PulseAudio capture" << std::endl;
  return true;
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

  std::cout << "INFO: Stopped audio capture" << std::endl;
}

void LinuxSysAudioCapturer::Release() {
  CleanupPulseAudio();
}

void LinuxSysAudioCapturer::SetCallback(AudioDataCallback callback, void* user_data) {
  std::lock_guard<std::mutex> lock(mutex_);
  callback_ = callback;
  user_data_ = user_data;
  std::cout << "VERBOSE: LinuxSysAudioCapturer::SetCallback()" << std::endl;
}

std::vector<std::pair<std::string, std::string>> 
LinuxSysAudioCapturer::GetRecordingDevices() {
  std::vector<std::pair<std::string, std::string>> devices;
  
  // 创建主循环和上下文
  pa_mainloop* mainloop = pa_mainloop_new();
  if (!mainloop) {
    std::cerr << "ERROR: Failed to create PulseAudio mainloop" << std::endl;
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
      std::cerr << "ERROR: PulseAudio context failed to connect" << std::endl;
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
    std::cerr << "ERROR: Failed to get sink info list" << std::endl;
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
    std::cerr << "WARNING: No monitor sources found, adding default" << std::endl;
    devices.push_back({"default", "Default Audio Device"});
  }
  
  // 断开连接并清理
  pa_context_disconnect(context);
  pa_context_unref(context);
  pa_mainloop_free(mainloop);
  
  std::cout << "INFO: Found " << devices.size() << " monitor sources" << std::endl;
  for (const auto& device : devices) {
    std::cout << "INFO:   - " << device.second << " (" << device.first << ")" << std::endl;
  }
  
  return devices;
}

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
    std::cerr << "ERROR: Failed to create PulseAudio stream: " 
              << pa_strerror(error) << std::endl;
    return false;
  }

  std::cout << "INFO: PulseAudio initialized successfully" << std::endl;
  std::cout << "INFO: Sample rate: " << sample_spec_.rate 
            << ", Channels: " << (uint32_t) sample_spec_.channels
            << ", Format: S16LE" << std::endl;
  return true;
}

void LinuxSysAudioCapturer::CleanupPulseAudio() {
  if (pulse_stream_) {
    pa_simple_free(pulse_stream_);
    pulse_stream_ = nullptr;
    std::cout << "INFO: PulseAudio stream cleaned up" << std::endl;
  }
}

void LinuxSysAudioCapturer::CaptureThread() {
  std::cout << "INFO: PulseAudio capture thread started" << std::endl;
  
  // 缓冲区大小（根据采样率和帧数计算）
  const size_t frames_per_buffer = 480;  // 10ms @ 48kHz
  const size_t bytes_per_frame = channels_ * (bits_per_sample_ / 8);
  const size_t buffer_size = frames_per_buffer * bytes_per_frame;
  
  std::vector<uint8_t> buffer(buffer_size);
  
  while (!should_stop_) {
    int error;
    
    // 从 PulseAudio 读取数据
    if (pa_simple_read(pulse_stream_, buffer.data(), buffer_size, &error) < 0) {
      std::cerr << "ERROR: Failed to read from PulseAudio: " 
                << pa_strerror(error) << std::endl;
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
  
  std::cout << "INFO: PulseAudio capture thread stopped" << std::endl;
}

// 静态方法：检查是否支持系统音频捕获
bool LinuxSysAudioCapturer::IsSystemAudioCaptureSupported() {
  return true;
}

}  // namespace flutter_webrtc_plugin

//#endif  // __linux__
