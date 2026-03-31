#ifndef SYS_AUDIO_SOURCE_HXX
#define SYS_AUDIO_SOURCE_HXX

#include <iostream>
#include "rtc_audio_source.h"
#include "rtc_peerconnection_factory.h"
#include <cstring>
#include <memory>
#include <string>
#include <fstream>
#include <vector>

#if defined(_WIN32) || defined(WINDOWS)
#include "win_sys_audio_capturer.h"
#elif defined(__linux__) || defined(LINUX)
#include "linux_sys_audio_capturer.h"
#else
#pragma message("SysAudioSource is only available on Windows and Linux (stub)")
#endif

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class RingBuffer {
 public:
  explicit RingBuffer(size_t capacity_bytes)
      : buffer_(capacity_bytes), read_pos_(0), write_pos_(0) {
  }
  uint8_t* GetPointer() {
    return buffer_.data() + read_pos_;
  }
  size_t GetSize() const {
    return write_pos_ - read_pos_;
  }

  void MakeRoom(size_t incoming_data_size) {
    if (buffer_.size() - write_pos_ < incoming_data_size) {
      size_t valid_size = GetSize();

      if (valid_size > 0) {
        std::memmove(buffer_.data(), buffer_.data() + read_pos_, valid_size);
      }

      write_pos_ = valid_size;
      read_pos_ = 0;
    }
  }
  void Write(const uint8_t* data, size_t size) {
    std::memcpy(buffer_.data() + write_pos_, data, size);
    write_pos_ += size;
  }
  size_t Read(uint8_t* out_data, size_t requested_size) {
    size_t current_size = GetSize();
    if (requested_size > current_size) {
      return 0;
    }
    std::memcpy(out_data, buffer_.data() + read_pos_, requested_size);
    read_pos_ += requested_size;
    return requested_size;
  }
  void Consume(size_t size) {
    if (read_pos_ + size <= write_pos_) {
      read_pos_ += size;
    }
    // 重置
    if (read_pos_ == write_pos_) {
      read_pos_ = 0;
      write_pos_ = 0;
    }
  }
  void Clear() {
    read_pos_ = 0;
    write_pos_ = 0;
  }

 public:
  std::vector<uint8_t> buffer_;
  size_t read_pos_;
  size_t write_pos_;
};


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
    int bytes_per_frame = bits_per_sample / 8 * static_cast<int>(number_of_channels);
    int bytes_size = bytes_per_frame * static_cast<int>(number_of_frames);
    audio_buffer.MakeRoom(bytes_size);
    audio_buffer.Write(static_cast<const uint8_t*>(audio_data), bytes_size);

    if (enable_pcm_recording_ && pcm_file_.is_open()) {
      pcm_file_.write(static_cast<const char*>(audio_data), bytes_size);
      pcm_file_.flush();
      total_frames_recorded_ += number_of_frames;
    }

    int target_frames = capturer_->preferred_sample_rate_ / 100;
    if (rtc_audio_source_) {
      size_t target_bytes = target_frames * bytes_per_frame;
//      std::cout << "sink size:" << rtc_audio_source_->GetSinkSize() << std::endl;
//      std::cout << bits_per_sample << " " << sample_rate << " " << number_of_channels << " " << number_of_frames << std::endl;
      while (audio_buffer.GetSize() >= target_bytes) {
        rtc_audio_source_->CaptureFrame(audio_buffer.GetPointer(), bits_per_sample, sample_rate,
                                        number_of_channels, target_frames);
        audio_buffer.Consume(target_bytes);
      }
//      createData();
    }  else {
      std::cout << "rtc_audio_source_ is null" << std::endl;
    }
  }

  void createData() {
    const int sample_rate = 48000;
    const int channels = 2;
    const int bits_per_sample = 16;
    const int duration_ms = 10; // 10毫秒

    int number_of_frames = (sample_rate * duration_ms) / 1000;
    int buffer_size = number_of_frames * channels * (bits_per_sample / 8);

    uint8_t* audio_data = new uint8_t[buffer_size];

    int16_t* samples = reinterpret_cast<int16_t*>(audio_data);
    double frequency = 440.0; // A4 音符

    for (int i = 0; i < number_of_frames; ++i) {
      double value = 0.5 * sin(2.0 * 3.14159265358979323846 * frequency * i / sample_rate);
      int16_t sample_val = static_cast<int16_t>(value * 32767);
      samples[i * 2] = sample_val;
      samples[i * 2 + 1] = sample_val;
    }
    std::cout << bits_per_sample << " " << sample_rate << " " << channels << " " << number_of_frames << std::endl;
    rtc_audio_source_->CaptureFrame(audio_data, bits_per_sample, sample_rate,
                                    channels, number_of_frames);
    delete[] audio_data;
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

  RingBuffer audio_buffer;
};

}  // namespace flutter_webrtc_plugin

#endif  // SYS_AUDIO_SOURCE_HXX
