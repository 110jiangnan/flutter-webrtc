#include "webrtc_sys_audio_source.h"

#include <iostream>

namespace webrtc {

using namespace libwebrtc;

WebrtcSysAudioSource::WebrtcSysAudioSource(
    scoped_refptr<RTCPeerConnectionFactory> factory,
    const std::string& audio_source_label)
    : factory_(factory),
      audio_source_label_(audio_source_label),
      audio_buffer(10240) {
  // 系统音频不经过 AGC/降噪/回声消除(那是给麦克风的)
  RTCAudioOptions options;
  options.echo_cancellation = false;
  options.noise_suppression = false;
  options.auto_gain_control = false;
  options.highpass_filter = false;

  rtc_audio_source_ = factory_->CreateAudioSource(
      audio_source_label.c_str(), RTCAudioSource::SourceType::kCustom, options);
  if (rtc_audio_source_) {
    capturer_ = std::make_unique<PlatformSysAudioCapturer>();
    capturer_->SetCallback(&WebrtcSysAudioSource::OnAudioDataCallback, this);
  }
}

WebrtcSysAudioSource::~WebrtcSysAudioSource() {
  StopCapture();
  rtc_audio_source_ = nullptr;
}

bool WebrtcSysAudioSource::Initialize(const std::string& device_id) {
  if (!capturer_) return false;
  return capturer_->Initialize(device_id);
}

bool WebrtcSysAudioSource::StartCapture() {
  if (!capturer_) return false;
  if (capturer_->IsCapturing()) return true;
  return capturer_->StartCapture();
}

void WebrtcSysAudioSource::StopCapture() {
  if (capturer_ && capturer_->IsCapturing()) capturer_->StopCapture();
}

bool WebrtcSysAudioSource::IsCapturing() const {
  return capturer_ ? capturer_->IsCapturing() : false;
}

void WebrtcSysAudioSource::OnAudioDataCallback(const void* audio_data,
                                               int bits_per_sample,
                                               int sample_rate,
                                               size_t number_of_channels,
                                               size_t number_of_frames,
                                               void* user_data) {
  WebrtcSysAudioSource* self = static_cast<WebrtcSysAudioSource*>(user_data);
  if (self) {
    self->CaptureFrame(audio_data, bits_per_sample, sample_rate,
                       number_of_channels, number_of_frames);
  }
}

}  // namespace webrtc
