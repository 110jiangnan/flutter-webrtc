#ifndef SYS_AUDIO_SOURCE_HXX
#define SYS_AUDIO_SOURCE_HXX

#include <iostream>
#include "rtc_audio_source.h"
#include "rtc_peerconnection_factory.h"

#include <memory>
#include <string>
#include <fstream>

#if defined(_WIN32) || defined(WINDOWS)
#include "win_sys_audio_capturer.h"
#elif defined(__linux__) || defined(LINUX)
#include "linux_sys_audio_capturer.h"
#else
#pragma message("SysAudioSource is only available on Windows and Linux (stub)")
#endif

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

#if defined(_WIN32) || defined(WINDOWS)
using PlatformSysAudioCapturer = WinSysAudioCapturer;
#elif defined(__linux__) || defined(LINUX)
using PlatformSysAudioCapturer = LinuxSysAudioCapturer;
#endif

class SysAudioSource : public RTCAudioSource {
 public:
  SysAudioSource(scoped_refptr<RTCPeerConnectionFactory> factory,
                 const std::string& audio_source_label = "sys_audio_input");
  
  ~SysAudioSource() override;

  bool Initialize(const std::string& device_id = "");
  
  bool StartCapture();
  
  void StopCapture();
  
  bool IsCapturing() const;

  void CaptureFrame(const void* audio_data, int bits_per_sample,
                    int sample_rate, size_t number_of_channels,
                    size_t number_of_frames) override {
    if (enable_pcm_recording_ && pcm_file_.is_open()) {
      pcm_file_.write(static_cast<const char*>(audio_data),
                      bits_per_sample / 8 * number_of_channels * number_of_frames);
      pcm_file_.flush();
      total_frames_recorded_ += number_of_frames;
    }
    
    if (rtc_audio_source_) {
      rtc_audio_source_->CaptureFrame(audio_data, bits_per_sample, sample_rate,
                                number_of_channels, number_of_frames);
    }
  }

  SourceType GetSourceType() const override { 
    return SourceType::kCustom; 
  }

  scoped_refptr<RTCAudioSource> rtc_audio_source() {
    return rtc_audio_source_; 
  }
  
  void EnablePcmRecording(bool enable, const std::string& file_path) {
    if (enable) {
      pcm_file_.open(file_path, std::ios::binary);
      if (pcm_file_.is_open()) {
        enable_pcm_recording_ = true;
        total_frames_recorded_ = 0;
        std::cout << "PCM recording started: " << file_path << std::endl;
      } else {
        std::cout << "Failed to open PCM file: " << file_path << std::endl;
      }
    } else {
      enable_pcm_recording_ = false;
      if (pcm_file_.is_open()) {
        pcm_file_.close();
        std::cout << "PCM recording stopped. Total frames: " 
                  << total_frames_recorded_ << std::endl;
      }
    }
  }
  
  bool IsPcmRecordingEnabled() const {
    return enable_pcm_recording_;
  }

 private:
  static void OnAudioDataCallback(const void* audio_data,
                                  int bits_per_sample,
                                  int sample_rate,
                                  size_t number_of_channels,
                                  size_t number_of_frames,
                                  void* user_data);

  std::unique_ptr<PlatformSysAudioCapturer> capturer_;

  scoped_refptr<RTCPeerConnectionFactory> factory_;
  scoped_refptr<RTCAudioSource> rtc_audio_source_;
  std::string audio_source_label_;
  
  bool enable_pcm_recording_ = false;
  std::ofstream pcm_file_;
  size_t total_frames_recorded_ = 0;
};

}  // namespace flutter_webrtc_plugin

#endif  // SYS_AUDIO_SOURCE_HXX
