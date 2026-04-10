#include "sys_audio_source.h"
#include <iostream>

namespace flutter_webrtc_plugin {

SysAudioSource::SysAudioSource(
    scoped_refptr<RTCPeerConnectionFactory> factory,
    const std::string& audio_source_label)
    : factory_(factory), audio_source_label_(audio_source_label), audio_buffer(10240) {
  std::cout << "Creating SysAudioSource: " << audio_source_label;
  
  RTCAudioOptions options;
  options.echo_cancellation = false;
  options.noise_suppression = false;
  options.auto_gain_control = false;
  options.highpass_filter = false;
  
  rtc_audio_source_ = factory_->CreateAudioSource(
      audio_source_label.c_str(), 
      RTCAudioSource::SourceType::kCustom,
      options);
  
  if (rtc_audio_source_) {
    capturer_ = std::make_unique<PlatformSysAudioCapturer>();
    capturer_->SetCallback(&SysAudioSource::OnAudioDataCallback, this);
    std::cout << "SysAudioSource created successfully" << std::endl;
  } else {
    std::cout << "Failed to create RTCAudioSource" << std::endl;
  }
}

SysAudioSource::~SysAudioSource() {
  std::cout << "Destroying SysAudioSource" << std::endl;
  StopCapture();
  rtc_audio_source_ = nullptr;
}

bool SysAudioSource::Initialize(const std::string& device_id) {
  if (!capturer_) {
    std::cout << "Capturer not initialized" << std::endl;
    return false;
  }
  
  bool result = capturer_->Initialize(device_id);
  if (result) {
    std::cout << "SysAudioSource initialized with device: " 
                     << (device_id.empty() ? "default" : device_id) << std::endl;
  } else {
    std::cout << "Failed to initialize SysAudioSource (platform may not support it)" << std::endl;
  }
  return result;
}

bool SysAudioSource::StartCapture() {
  if (!capturer_) {
    std::cout << "Cannot start capture - capturer is null" << std::endl;
    return false;
  }
  
  if (capturer_->IsCapturing()) {
    std::cout << "Already capturing" << std::endl;
    return true;
  }
  
  bool result = capturer_->StartCapture();
  if (result) {
    std::cout << "Started sys audio capture" << std::endl;
  } else {
    std::cout << "Failed to start sys audio capture (platform may not support it)" << std::endl;
  }
  return result;
}

void SysAudioSource::StopCapture() {
  if (capturer_ && capturer_->IsCapturing()) {
    capturer_->StopCapture();
    std::cout << "Stopped sys audio capture" << std::endl;
  }
}

bool SysAudioSource::IsCapturing() const {
  return capturer_ ? capturer_->IsCapturing() : false;
}

void SysAudioSource::OnAudioDataCallback(const void* audio_data,
                                         int bits_per_sample,
                                         int sample_rate,
                                         size_t number_of_channels,
                                         size_t number_of_frames,
                                         void* user_data) {
  SysAudioSource* self = static_cast<SysAudioSource*>(user_data);
  if (self) {
    self->CaptureFrame(audio_data, bits_per_sample, sample_rate,
                      number_of_channels, number_of_frames);
  }
}

}  // namespace flutter_webrtc_plugin

