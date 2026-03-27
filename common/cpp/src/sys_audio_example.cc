// 绯荤粺闊抽�鎹曡幏浣跨敤绀轰緥
// System Audio Capture Example

#include "sys_audio_source.h"
#include "flutter_webrtc_base.h"
#include <iostream>

namespace flutter_webrtc_plugin {

scoped_refptr<RTCMediaStream> CreateSysAudioStream(
    FlutterWebRTCBase* base,
    const std::string& device_id = "") {
  
  if (!base || !base->factory_) {
    std::cout << "Invalid base or factory";
    return nullptr;
  }
  
#if defined(_WIN32) || defined(WINDOWS)
  auto sys_audio_source = new rtc::RefCountedObject<SysAudioSource>(
      base->factory_, "sys_audio_capture");
  
  if (!sys_audio_source->rtc_audio_source()) {
    std::cout << "Failed to create sys audio source";
    return nullptr;
  }
  
  if (!sys_audio_source->Initialize(device_id)) {
    std::cout << "Failed to initialize audio capturer";
    return nullptr;
  }
  
  std::string uuid = base->GenerateUUID();
  scoped_refptr<RTCAudioTrack> audio_track = 
      base->factory_->CreateAudioTrack(
          sys_audio_source->rtc_audio_source(), 
          uuid.c_str());
  
  if (!audio_track) {
    std::cout << "Failed to create audio track";
    return nullptr;
  }
  
  std::string stream_id = base->GenerateUUID();
  scoped_refptr<RTCMediaStream> stream = 
      base->factory_->CreateStream(stream_id.c_str());
  
  if (!stream) {
    std::cout << "Failed to create media stream";
    return nullptr;
  }
  
  stream->AddTrack(audio_track);
  
  base->local_tracks_[audio_track->id().std_string()] = audio_track;
  
  if (!sys_audio_source->StartCapture()) {
    std::cout << "Failed to start audio capture";
    return nullptr;
  }
  
  std::cout << "Created sys audio capture stream: " 
                   << stream->id().std_string();
  
  return stream;
  
#else
  std::cout << "System audio capture is only available on Windows";
  return nullptr;
#endif
}

EncodableList GetSysAudioDevices() {
  EncodableList devices;
  
#if defined(_WIN32) || defined(WINDOWS)
  auto recording_devices = SysAudioCapturer::GetRecordingDevices();
  
  for (const auto& device : recording_devices) {
    EncodableMap device_info;
    device_info[EncodableValue("id")] = EncodableValue(device.first);
    device_info[EncodableValue("name")] = EncodableValue(device.second);
    device_info[EncodableValue("kind")] = EncodableValue("audioinput");
    devices.push_back(EncodableValue(device_info));
  }
  
  std::cout << "Found " << devices.size() << " recording devices";
#else
  std::cout << "System audio devices not available on this platform";
#endif
  
  return devices;
}

}  // namespace flutter_webrtc_plugin

// ============================================================================
// Dart/Flutter Usage Example
// ============================================================================
/*
import 'package:flutter/services.dart';

class SystemAudioPlugin {
  static const MethodChannel _channel = MethodChannel('flutter_webrtc');
  
  static Future<List<Map<String, dynamic>>> getSysAudioDevices() async {
    final List<dynamic> devices = await _channel.invokeMethod('getSysAudioDevices');
    return devices.map((d) => Map<String, dynamic>.from(d)).toList();
  }
  
  static Future<MediaStream> createSysAudioStream({String? deviceId}) async {
    return await _channel.invokeMethod('createSysAudioStream', {
      'deviceId': deviceId,
    });
  }
  
  static Future<void> addSysAudioToCall(
    RTCPeerConnection pc,
    String? deviceId,
  ) async {
    final stream = await createSysAudioStream(deviceId: deviceId);
    final track = stream.getAudioTracks()[0];
    await pc.addTrack(track, [stream]);
  }
}
*/

