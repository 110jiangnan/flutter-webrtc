#ifndef FLUTTER_WEBRTC_SYS_AUDIO_MANAGER_H
#define FLUTTER_WEBRTC_SYS_AUDIO_MANAGER_H

#include "libwebrtc.h"
#include "sys_audio_source.h"
#include <map>
#include <mutex>
#include <string>

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

class SysAudioManager {
 public:
  static SysAudioManager* GetInstance();
  
  static void DestroyInstance();
  
  bool Initialize(scoped_refptr<RTCPeerConnectionFactory> factory,
                  const std::string& device_id = "");
  
  scoped_refptr<RTCMediaStream> CreateSysAudioMediaStream(
      scoped_refptr<RTCPeerConnectionFactory> factory,
      const std::string& stream_id = "");
  
  scoped_refptr<RTCAudioTrack> CreateSysAudioTrack(
      scoped_refptr<RTCPeerConnectionFactory> factory,
      const std::string& track_id = "");
  
  bool StartCapture();
  
  void StopCapture();
  
  bool IsCapturing() const;
  
  bool IsInitialized() const;
  
  std::string current_device_id() const { return current_device_id_; }
  
  std::map<std::string, std::string> GetRecordingDevices();
  
  bool SwitchDevice(const std::string& device_id);
  
  void EnablePcmRecording(bool enable, const std::string& file_path);
  
  scoped_refptr<SysAudioSource> GetAudioSource() { return audio_source_; }
  
  void Release();

 private:
  SysAudioManager();
  ~SysAudioManager();
  
  SysAudioManager(const SysAudioManager&) = delete;
  SysAudioManager& operator=(const SysAudioManager&) = delete;
  
  static SysAudioManager* g_instance;
  static std::mutex g_mutex;
  
  scoped_refptr<SysAudioSource> audio_source_;
  bool is_initialized_;
  bool is_capturing_;
  std::string current_device_id_;
};

}  // namespace flutter_webrtc_plugin

#endif  // !FLUTTER_WEBRTC_SYS_AUDIO_MANAGER_H
