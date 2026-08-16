#ifndef WEBRTC_SYS_AUDIO_SOURCE_HXX
#define WEBRTC_SYS_AUDIO_SOURCE_HXX

/* 对应 sys_audio_source.h 的 SysAudioSource:
 * 自定义 RTCAudioSource(kCustom), 内部套一个平台系统音频 capturer,
 * 用 RingBuffer 攒够 10ms 再喂给 libwebrtc 的 rtc_audio_source_。
 * 平台 capturer 由宏按系统选择(WASAPI / PulseAudio)。 */
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "rtc_audio_source.h"
#include "rtc_peerconnection_factory.h"

#if defined(_WIN32) || defined(WINDOWS)
#include "webrtc_win_sys_audio_capturer.h"
#elif defined(__linux__) || defined(LINUX)
#include "webrtc_linux_sys_audio_capturer.h"
#endif

namespace webrtc {

using namespace libwebrtc;

class RingBuffer {
 public:
  RingBuffer() : buffer_(10240), read_pos_(0), write_pos_(0) {}
  explicit RingBuffer(size_t capacity_bytes)
      : buffer_(capacity_bytes), read_pos_(0), write_pos_(0) {}

  uint8_t* GetPointer() { return buffer_.data() + read_pos_; }
  size_t GetSize() const { return write_pos_ - read_pos_; }

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
  void Consume(size_t size) {
    if (read_pos_ + size <= write_pos_) read_pos_ += size;
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
using PlatformSysAudioCapturer = WebrtcWinSysAudioCapturer;
#elif defined(__linux__) || defined(LINUX)
using PlatformSysAudioCapturer = WebrtcLinuxSysAudioCapturer;
#endif

class WebrtcSysAudioSource : public RTCAudioSource {
 public:
  WebrtcSysAudioSource(scoped_refptr<RTCPeerConnectionFactory> factory,
                       const std::string& audio_source_label = "sys_audio_input");

  ~WebrtcSysAudioSource() override;

  bool Initialize(const std::string& device_id = "");

  bool StartCapture();

  void StopCapture();

  bool IsCapturing() const;

  // capturer 回调线程: 攒进 RingBuffer, 凑满 10ms 后喂给 rtc_audio_source_
  void CaptureFrame(const void* audio_data, int bits_per_sample,
                    int sample_rate, size_t number_of_channels,
                    size_t number_of_frames) override {
    const uint8_t* audio_data1 = static_cast<const uint8_t*>(audio_data);
    int bytes_per_frame =
        bits_per_sample / 8 * static_cast<int>(number_of_channels);
    int bytes_size = bytes_per_frame * static_cast<int>(number_of_frames);
    audio_buffer.MakeRoom(bytes_size);
    audio_buffer.Write(audio_data1, bytes_size);

    if (enable_pcm_recording_ && pcm_file_.is_open()) {
      pcm_file_.write(static_cast<const char*>(audio_data), bytes_size);
      pcm_file_.flush();
      total_frames_recorded_ += number_of_frames;
    }

    if (!rtc_audio_source_) return;
    int target_frames = capturer_ ? capturer_->preferred_sample_rate_ / 100 : 480;
    size_t target_bytes = target_frames * bytes_per_frame;
    while (audio_buffer.GetSize() >= target_bytes) {
      rtc_audio_source_->CaptureFrame(audio_buffer.GetPointer(), bits_per_sample,
                                      sample_rate, number_of_channels,
                                      target_frames);
      audio_buffer.Consume(target_bytes);
    }
  }

  SourceType GetSourceType() const override { return SourceType::kCustom; }

  scoped_refptr<RTCAudioSource> rtc_audio_source() { return rtc_audio_source_; }

  void EnablePcmRecording(bool enable, const std::string& file_path) {
    if (enable) {
      pcm_file_.open(file_path, std::ios::binary);
      if (pcm_file_.is_open()) {
        enable_pcm_recording_ = true;
        total_frames_recorded_ = 0;
      }
    } else {
      enable_pcm_recording_ = false;
      if (pcm_file_.is_open()) pcm_file_.close();
    }
  }

  bool IsPcmRecordingEnabled() const { return enable_pcm_recording_; }

 private:
  static void OnAudioDataCallback(const void* audio_data, int bits_per_sample,
                                  int sample_rate, size_t number_of_channels,
                                  size_t number_of_frames, void* user_data);

  std::unique_ptr<PlatformSysAudioCapturer> capturer_;

  scoped_refptr<RTCPeerConnectionFactory> factory_;
  scoped_refptr<RTCAudioSource> rtc_audio_source_;
  std::string audio_source_label_;

  bool enable_pcm_recording_ = false;
  std::ofstream pcm_file_;
  size_t total_frames_recorded_ = 0;

  RingBuffer audio_buffer;
};

}  // namespace webrtc

#endif  // WEBRTC_SYS_AUDIO_SOURCE_HXX
