// webrtc_linux_sys_audio_capturer.cc — PulseAudio Monitor 源系统音频采集(参考 linux_sys_audio_capturer.cc)
// 仅 Linux 构建; 需要 libpulse-simple。

#include "webrtc_linux_sys_audio_capturer.h"

#include <cstring>
#include <iostream>

#include <pulse/pulseaudio.h>

namespace webrtc {

struct SinkInfoData {
  std::vector<std::pair<std::string, std::string>>* devices;
  bool done;
};

void sink_info_callback(pa_context* context, const pa_sink_info* info, int eol,
                        void* userdata) {
  if (eol < 0) return;
  if (eol == 1) {
    SinkInfoData* data = static_cast<SinkInfoData*>(userdata);
    data->done = true;
    return;
  }
  if (!info || !info->name) return;

  std::string monitor_name = std::string(info->name) + ".monitor";
  std::string description =
      info->description ? std::string(info->description) + " (Monitor)"
                        : monitor_name;
  SinkInfoData* data = static_cast<SinkInfoData*>(userdata);
  data->devices->push_back({monitor_name, description});
}

WebrtcLinuxSysAudioCapturer::WebrtcLinuxSysAudioCapturer() {}

WebrtcLinuxSysAudioCapturer::~WebrtcLinuxSysAudioCapturer() {
  StopCapture();
  Release();
}

bool WebrtcLinuxSysAudioCapturer::Initialize(const std::string& device_id) {
  return InitializePulseAudio(device_id);
}

bool WebrtcLinuxSysAudioCapturer::StartCapture() {
  if (!pulse_stream_) {
    std::cerr << "ERROR: Cannot start capture - PulseAudio not initialized"
              << std::endl;
    return false;
  }
  if (is_capturing_) return true;

  should_stop_ = false;
  is_capturing_ = true;
  capture_thread_ =
      std::thread(&WebrtcLinuxSysAudioCapturer::CaptureThread, this);
  return true;
}

void WebrtcLinuxSysAudioCapturer::StopCapture() {
  if (!is_capturing_) return;
  should_stop_ = true;
  is_capturing_ = false;
  if (capture_thread_.joinable()) capture_thread_.join();
}

void WebrtcLinuxSysAudioCapturer::Release() { CleanupPulseAudio(); }

void WebrtcLinuxSysAudioCapturer::SetCallback(AudioDataCallback callback,
                                              void* user_data) {
  std::lock_guard<std::mutex> lock(mutex_);
  callback_ = callback;
  user_data_ = user_data;
}

std::vector<std::pair<std::string, std::string>>
WebrtcLinuxSysAudioCapturer::GetRecordingDevices() {
  std::vector<std::pair<std::string, std::string>> devices;

  pa_mainloop* mainloop = pa_mainloop_new();
  if (!mainloop) return devices;
  pa_context* context = pa_context_new(pa_mainloop_get_api(mainloop),
                                       "sys_audio_devices");
  if (!context) {
    pa_mainloop_free(mainloop);
    return devices;
  }
  if (pa_context_connect(context, nullptr, PA_CONTEXT_NOFAIL, nullptr) < 0) {
    pa_context_unref(context);
    pa_mainloop_free(mainloop);
    return devices;
  }

  pa_context_state_t state;
  while ((state = pa_context_get_state(context)) != PA_CONTEXT_READY) {
    if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
      pa_context_unref(context);
      pa_mainloop_free(mainloop);
      return devices;
    }
    pa_mainloop_iterate(mainloop, 1, nullptr);
  }

  SinkInfoData data;
  data.devices = &devices;
  data.done = false;

  pa_operation* op =
      pa_context_get_sink_info_list(context, sink_info_callback, &data);
  if (!op) {
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_mainloop_free(mainloop);
    return devices;
  }
  while (!data.done) pa_mainloop_iterate(mainloop, 1, nullptr);
  pa_operation_unref(op);

  if (devices.empty()) devices.push_back({"default", "Default Audio Device"});

  pa_context_disconnect(context);
  pa_context_unref(context);
  pa_mainloop_free(mainloop);
  return devices;
}

bool WebrtcLinuxSysAudioCapturer::InitializePulseAudio(
    const std::string& device_id) {
  pa_sample_spec sample_spec;
  sample_spec.format = PA_SAMPLE_S16LE;
  sample_spec.rate = sample_rate_;
  sample_spec.channels = channels_;

  std::string actual_device_id = device_id;
  if (actual_device_id.empty()) {
    auto devices = GetRecordingDevices();
    if (!devices.empty()) {
      actual_device_id = devices[0].first;
    } else {
      std::cerr << "ERROR: No monitor sources available" << std::endl;
      return false;
    }
  }

  int error;
  pulse_stream_ = pa_simple_new(nullptr, "System Audio Capture",
                                PA_STREAM_RECORD, actual_device_id.c_str(),
                                "Record", &sample_spec, nullptr, nullptr,
                                &error);
  if (!pulse_stream_) {
    std::cerr << "ERROR: Failed to create PulseAudio stream: "
              << pa_strerror(error) << std::endl;
    return false;
  }
  return true;
}

void WebrtcLinuxSysAudioCapturer::CleanupPulseAudio() {
  if (pulse_stream_) {
    pa_simple_free(static_cast<pa_simple*>(pulse_stream_));
    pulse_stream_ = nullptr;
  }
}

void WebrtcLinuxSysAudioCapturer::CaptureThread() {
  const size_t frames_per_buffer = 480;  // 10ms @ 48kHz
  const size_t bytes_per_frame = channels_ * (bits_per_sample_ / 8);
  const size_t buffer_size = frames_per_buffer * bytes_per_frame;

  std::vector<uint8_t> buffer(buffer_size);
  pa_simple* stream = static_cast<pa_simple*>(pulse_stream_);

  while (!should_stop_) {
    int error;
    if (pa_simple_read(stream, buffer.data(), buffer_size, &error) < 0) {
      std::cerr << "ERROR: Failed to read from PulseAudio: "
                << pa_strerror(error) << std::endl;
      break;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (callback_) {
        callback_(buffer.data(), bits_per_sample_, sample_rate_, channels_,
                  frames_per_buffer, user_data_);
      }
    }
  }
}

bool WebrtcLinuxSysAudioCapturer::IsSystemAudioCaptureSupported() {
  return true;
}

}  // namespace webrtc
