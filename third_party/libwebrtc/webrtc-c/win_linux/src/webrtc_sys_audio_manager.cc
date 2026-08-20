#include "webrtc_sys_audio_manager.h"

#include <iostream>

#include "base/refcountedobject.h"

namespace webrtc {

using namespace libwebrtc;

WebrtcSysAudioManager* WebrtcSysAudioManager::g_instance = nullptr;
std::mutex WebrtcSysAudioManager::g_mutex;

WebrtcSysAudioManager* WebrtcSysAudioManager::GetInstance() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_instance) g_instance = new WebrtcSysAudioManager();
  return g_instance;
}

void WebrtcSysAudioManager::DestroyInstance() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_instance) {
    g_instance->Release();
    delete g_instance;
    g_instance = nullptr;
  }
}

WebrtcSysAudioManager::WebrtcSysAudioManager()
    : audio_source_(nullptr),
      is_initialized_(false),
      is_capturing_(false),
      current_device_id_("") {}

WebrtcSysAudioManager::~WebrtcSysAudioManager() { Release(); }

bool WebrtcSysAudioManager::Initialize(WebrtcBase* base,
                                       const std::string& device_id) {
  if (!base->empty_adm_factory_) return false;
  if (is_initialized_) return true;

  audio_source_ = new RefCountedObject<WebrtcSysAudioSource>(
      base->empty_adm_factory_, "sys_audio_capture");
  if (!audio_source_->rtc_audio_source()) {
    audio_source_ = nullptr;
    return false;
  }
  if (!audio_source_->Initialize(device_id)) {
    audio_source_ = nullptr;
    return false;
  }
  if (!audio_source_->StartCapture()) {
    audio_source_ = nullptr;
    return false;
  }
  current_device_id_ = device_id;
  is_initialized_ = true;
  return true;
}

std::string WebrtcSysAudioManager::GetSysAudioMedia(WebrtcBase* base,
                                                    const std::string& stream_id) {
  if (!base->empty_adm_factory_ || !is_initialized_) return "";

  auto audio_track = CreateSysAudioTrack(base, "");
  if (!audio_track) return "";

  std::string actual_stream_id =
      stream_id.empty() ? base->GenerateUUID() : stream_id;
  scoped_refptr<RTCMediaStream> stream =
      base->empty_adm_factory_->CreateStream(actual_stream_id.c_str());
  if (!stream) return "";

  base->local_tracks_[audio_track->id().std_string()] = audio_track;
  stream->AddTrack(audio_track);
  base->local_streams_[actual_stream_id] = stream;

  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("streamId", MakeStr(stream->id().std_string()));
  result.obj.emplace_back("ownerTag", MakeStr("local"));

  JNode audio_tracks;
  audio_tracks.type = JNode::kArr;
  audio_tracks.arr.push_back(MakeObj({
      {"id", MakeStr(audio_track->id().std_string())},
      {"label", MakeStr(audio_track->id().std_string())},
      {"kind", MakeStr("audio")},
      {"enabled", MakeBool(audio_track->enabled())},
      {"settings", MakeObj({{"deviceId", MakeStr(current_device_id_)},
                            {"kind", MakeStr("audioinput")},
                            {"autoGainControl", MakeBool(false)},
                            {"echoCancellation", MakeBool(false)},
                            {"noiseSuppression", MakeBool(false)},
                            {"channelCount", MakeNum(2)}})},
  }));
  result.obj.emplace_back("audioTracks", std::move(audio_tracks));

  JNode video_tracks;
  video_tracks.type = JNode::kArr;
  result.obj.emplace_back("videoTracks", std::move(video_tracks));
  return ToJson(result);
}

scoped_refptr<RTCAudioTrack> WebrtcSysAudioManager::CreateSysAudioTrack(
    WebrtcBase* base, const std::string& track_id) {
  if (!base->empty_adm_factory_ || !is_initialized_) return nullptr;
  std::string actual_track_id =
      track_id.empty() ? base->GenerateUUID() : track_id;
  return base->empty_adm_factory_->CreateAudioTrack(
      audio_source_->rtc_audio_source(), actual_track_id.c_str());
}

bool WebrtcSysAudioManager::StartCapture() {
  if (!is_initialized_) return false;
  if (is_capturing_) return true;
  if (audio_source_->StartCapture()) {
    is_capturing_ = true;
    return true;
  }
  return false;
}

void WebrtcSysAudioManager::StopCapture() {
  if (!is_capturing_) return;
  if (audio_source_) {
    audio_source_->StopCapture();
    is_capturing_ = false;
  }
}

std::map<std::string, std::string> WebrtcSysAudioManager::GetRecordingDevices() {
  std::map<std::string, std::string> devices;  // 与参考一致, 返回空
  return devices;
}

bool WebrtcSysAudioManager::SwitchDevice(const std::string& device_id) {
  if (!is_initialized_) return false;
  if (device_id == current_device_id_) return true;
  StopCapture();
  audio_source_ = nullptr;
  is_initialized_ = false;
  return true;  // 切换需重新 Initialize(参考 SwitchDevice)
}

void WebrtcSysAudioManager::EnablePcmRecording(bool enable,
                                               const std::string& file_path) {
  if (audio_source_) audio_source_->EnablePcmRecording(enable, file_path);
}

void WebrtcSysAudioManager::Release() {
  StopCapture();
  audio_source_ = nullptr;
  is_initialized_ = false;
  is_capturing_ = false;
  current_device_id_ = "";
}

}  // namespace webrtc
