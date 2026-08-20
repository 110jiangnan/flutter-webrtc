#include "webrtc_media_stream.h"

#include <cstring>

#include "rtc_audio_device.h"
#include "rtc_media_track.h"
#include "rtc_mediaconstraints.h"

namespace webrtc {

using namespace libwebrtc;

#define DEFAULT_WIDTH 1280
#define DEFAULT_HEIGHT 720
#define DEFAULT_FPS 30

// 参考 flutter_media_stream.cc 的 getSourceIdConstraint / getDeviceIdConstraint:
// sourceId 从 audio/video 约束的 optional 数组里找, deviceId 在顶层
static std::string GetSourceIdConstraint(const JNode& media_constraints) {
  const JNode* optional = media_constraints.Get("optional");
  if (optional && optional->type == JNode::kArr) {
    for (auto& option : optional->arr) {
      if (option.type == JNode::kObj) {
        const JNode* source_id = option.Get("sourceId");
        if (source_id && source_id->type == JNode::kStr) return source_id->s;
      }
    }
  }
  return "";
}

static std::string GetDeviceIdConstraint(const JNode& media_constraints) {
  return media_constraints.StrOf("deviceId");
}

WebrtcMediaStream::WebrtcMediaStream(WebrtcBase* base) : base_(base) {}

std::string WebrtcMediaStream::GetUserMedia(const JNode& constraints) {
  std::string uuid = base_->GenerateUUID();
  scoped_refptr<RTCMediaStream> stream =
      base_->factory_->CreateStream(uuid.c_str());
  if (!stream) return "";

  JNode params;
  params.type = JNode::kObj;
  params.obj.emplace_back("streamId", MakeStr(uuid));
  JNode audio_tracks;
  audio_tracks.type = JNode::kArr;
  JNode video_tracks;
  video_tracks.type = JNode::kArr;

  // audio: true 或约束对象
  const JNode* audio = constraints.Get("audio");
  bool want_audio = audio && (audio->type == JNode::kBool ? audio->b
                                                          : audio->type == JNode::kObj);
  if (want_audio) {
    JNode track;
    if (GetUserAudio(*audio, stream.get(), &track))
      audio_tracks.arr.push_back(std::move(track));
  }

  // video: true 或约束对象
  const JNode* video = constraints.Get("video");
  bool want_video = video && (video->type == JNode::kBool ? video->b
                                                          : video->type == JNode::kObj);
  if (want_video) {
    JNode track;
    if (GetUserVideo(*video, stream.get(), &track))
      video_tracks.arr.push_back(std::move(track));
  }

  // 流按 streamId 保存, dart 侧用 id 引用; 不用时 webrtc_stream_dispose
  base_->local_streams_[uuid] = stream;

  params.obj.emplace_back("audioTracks", std::move(audio_tracks));
  params.obj.emplace_back("videoTracks", std::move(video_tracks));
  return ToJson(params);
}

bool WebrtcMediaStream::GetUserAudio(const JNode& audio, RTCMediaStream* stream,
                                     JNode* out) {
  // 参考 flutter_media_stream.cc GetUserAudio:
  //   audio 为 bool → enable_audio; 为 map → sourceId(optional数组)/deviceId
  bool enable_audio = false;
  std::string sourceId;
  std::string deviceId;
  if (audio.type == JNode::kBool) {
    enable_audio = audio.b;
  } else if (audio.type == JNode::kObj) {
    sourceId = GetSourceIdConstraint(audio);
    deviceId = GetDeviceIdConstraint(audio);
    enable_audio = true;
  }
  if (!enable_audio) return false;

  scoped_refptr<RTCAudioDevice> device = base_->factory_->GetAudioDevice();
  if (!device) return false;
  int16_t recording_devices = device->RecordingDevices();
  int16_t playout_devices = device->PlayoutDevices();
  if (recording_devices <= 0) return false;

  // 输入设备: 按 sourceId 选录音设备; 未指定则默认第 0 个并取其 guid
  char strRecordingName[256] = {0};
  char strRecordingGuid[256] = {0};
  for (int16_t i = 0; i < recording_devices; ++i) {
    device->RecordingDeviceName(i, strRecordingName, strRecordingGuid);
    if (sourceId != "" && sourceId == std::string(strRecordingGuid)) {
      device->SetRecordingDevice(i);
    }
  }
  if (sourceId == "") {
    device->RecordingDeviceName(0, strRecordingName, strRecordingGuid);
    sourceId = strRecordingGuid;
  }

  // 输出设备: 按 deviceId 选播放设备
  char strPlayoutName[256] = {0};
  char strPlayoutGuid[256] = {0};
  for (int16_t i = 0; i < playout_devices; ++i) {
    device->PlayoutDeviceName(i, strPlayoutName, strPlayoutGuid);
    if (deviceId != "" && deviceId == std::string(strPlayoutGuid)) {
      device->SetPlayoutDevice(i);
    }
  }

  scoped_refptr<RTCAudioSource> source =
      base_->factory_->CreateAudioSource("audio_input");
  if (!source) return false;
  std::string track_id = base_->GenerateUUID();
  scoped_refptr<RTCAudioTrack> track =
      base_->factory_->CreateAudioTrack(source, track_id.c_str());
  if (!track) return false;

  stream->AddTrack(track);
  base_->local_tracks_[track->id().std_string()] = track;

  *out = MakeObj({
      {"id", MakeStr(track->id().std_string())},
      {"label", MakeStr(track->id().std_string())},
      {"kind", MakeStr("audio")},
      {"enabled", MakeBool(track->enabled())},
      {"settings", MakeObj({{"deviceId", MakeStr(sourceId)},
                            {"kind", MakeStr("audioinput")},
                            {"autoGainControl", MakeBool(true)},
                            {"echoCancellation", MakeBool(true)},
                            {"noiseSuppression", MakeBool(true)},
                            {"channelCount", MakeNum(1)},
                            {"latency", MakeNum(0)}})},
  });
  return true;
}

bool WebrtcMediaStream::GetUserVideo(const JNode& video, RTCMediaStream* stream,
                                     JNode* out) {
  // 参考 flutter_media_stream.cc GetUserVideo:
  //   宽高帧率优先级: 顶层(或 ideal) → mandatory.minWidth/minHeight/minFrameRate → mandatory.width/height/frameRate
  const JNode* mandatory = video.Get("mandatory");
  int width = ConstrainInt(video, "width", -1);
  if (width < 0 && mandatory) width = ConstrainInt(*mandatory, "minWidth", -1);
  if (width < 0 && mandatory) width = ConstrainInt(*mandatory, "width", -1);
  if (width < 0) width = DEFAULT_WIDTH;
  int height = ConstrainInt(video, "height", -1);
  if (height < 0 && mandatory) height = ConstrainInt(*mandatory, "minHeight", -1);
  if (height < 0 && mandatory) height = ConstrainInt(*mandatory, "height", -1);
  if (height < 0) height = DEFAULT_HEIGHT;
  int fps = ConstrainInt(video, "frameRate", -1);
  if (fps < 0 && mandatory) fps = ConstrainInt(*mandatory, "minFrameRate", -1);
  if (fps < 0 && mandatory) fps = ConstrainInt(*mandatory, "frameRate", -1);
  if (fps < 0) fps = DEFAULT_FPS;

  std::string sourceId = GetSourceIdConstraint(video);

  scoped_refptr<RTCVideoDevice> device = base_->factory_->GetVideoDevice();
  if (!device) return false;
  int nb_video_devices = device->NumberOfDevices();
  if (nb_video_devices <= 0) return false;

  char strNameUTF8[256] = {0};
  char strGuidUTF8[256] = {0};
  scoped_refptr<RTCVideoCapturer> capturer;
  for (int i = 0; i < nb_video_devices; ++i) {
    device->GetDeviceName(i, strNameUTF8, 256, strGuidUTF8, 256);
    if (sourceId != "" && sourceId == std::string(strGuidUTF8)) {
      capturer = device->Create(strNameUTF8, i, width, height, fps);
      break;
    }
  }

  // 未匹配到指定设备 → 默认第 0 个, 并把 sourceId 更新为它的 guid(settings 里用)
  if (!capturer) {
    device->GetDeviceName(0, strNameUTF8, 256, strGuidUTF8, 256);
    sourceId = strGuidUTF8;
    capturer = device->Create(strNameUTF8, 0, width, height, fps);
  }
  if (!capturer) return false;
  capturer->StartCapture();

  scoped_refptr<RTCMediaConstraints> media_constraints =
      base_->ParseMediaConstraints(video);
  scoped_refptr<RTCVideoSource> source = base_->factory_->CreateVideoSource(
      capturer, "video_input", media_constraints);
  if (!source) return false;

  std::string track_id = base_->GenerateUUID();
  scoped_refptr<RTCVideoTrack> track =
      base_->factory_->CreateVideoTrack(source, track_id.c_str());
  if (!track) return false;

  stream->AddTrack(track);

  // capturer 保活, 直到流销毁(同 flutter video_capturers_)
  base_->video_capturers_[track_id] = capturer;
  base_->local_tracks_[track_id] = track;

  *out = MakeObj({
      {"id", MakeStr(track_id)},
      {"label", MakeStr(track_id)},
      {"kind", MakeStr("video")},
      {"enabled", MakeBool(track->enabled())},
      {"settings", MakeObj({{"deviceId", MakeStr(sourceId)},
                            {"kind", MakeStr("videoinput")},
                            {"width", MakeNum(width)},
                            {"height", MakeNum(height)},
                            {"frameRate", MakeNum(fps)}})},
  });
  return true;
}

// ================= 被控: 设备/流/轨道管理(参考 flutter_media_stream.cc) =================

std::string WebrtcMediaStream::GetSources() {
  JNode sources;
  sources.type = JNode::kArr;

  scoped_refptr<RTCAudioDevice> audio_device = base_->factory_->GetAudioDevice();
  if (audio_device) {
    char name[RTCAudioDevice::kAdmMaxDeviceNameSize + 1] = {0};
    char guid[RTCAudioDevice::kAdmMaxGuidSize + 1] = {0};

    int16_t recording = audio_device->RecordingDevices();
    for (int16_t i = 0; i < recording; ++i) {
      audio_device->RecordingDeviceName(i, name, guid);
      std::string device_id = strlen(guid) > 0 ? std::string(guid)
                                               : std::string(name);
      sources.arr.push_back(MakeObj({{"label", MakeStr(std::string(name))},
                                     {"deviceId", MakeStr(device_id)},
                                     {"facing", MakeStr("")},
                                     {"kind", MakeStr("audioinput")}}));
    }

    int16_t playout = audio_device->PlayoutDevices();
    for (int16_t i = 0; i < playout; ++i) {
      audio_device->PlayoutDeviceName(i, name, guid);
      std::string device_id = strlen(guid) > 0 ? std::string(guid)
                                               : std::string(name);
      sources.arr.push_back(MakeObj({{"label", MakeStr(std::string(name))},
                                     {"deviceId", MakeStr(device_id)},
                                     {"facing", MakeStr("")},
                                     {"kind", MakeStr("audiooutput")}}));
    }
  }

  scoped_refptr<RTCVideoDevice> video_device = base_->factory_->GetVideoDevice();
  if (video_device) {
    char name[256] = {0};
    char guid[256] = {0};
    int nb = video_device->NumberOfDevices();
    for (int i = 0; i < nb; ++i) {
      video_device->GetDeviceName(i, name, 256, guid, 256);
      sources.arr.push_back(MakeObj({{"label", MakeStr(std::string(name))},
                                     {"deviceId", MakeStr(std::string(guid))},
                                     {"facing", MakeStr(i == 1 ? "front" : "back")},
                                     {"kind", MakeStr("videoinput")}}));
    }
  }

  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("sources", std::move(sources));
  return ToJson(result);
}

bool WebrtcMediaStream::SelectAudioInput(const std::string& device_id) {
  scoped_refptr<RTCAudioDevice> audio_device = base_->factory_->GetAudioDevice();
  if (!audio_device) return false;

  char name[RTCAudioDevice::kAdmMaxDeviceNameSize] = {0};
  char guid[RTCAudioDevice::kAdmMaxGuidSize] = {0};
  int16_t recording = audio_device->RecordingDevices();
  for (int16_t i = 0; i < recording; ++i) {
    audio_device->RecordingDeviceName(i, name, guid);
    std::string cur = strlen(guid) > 0 ? std::string(guid) : std::string(name);
    if (!device_id.empty() && device_id == cur) {
      audio_device->SetRecordingDevice(i);
      return true;
    }
  }
  return false;
}

std::string WebrtcMediaStream::CreateLocalMediaStream() {
  std::string uuid = base_->GenerateUUID();
  scoped_refptr<RTCMediaStream> stream =
      base_->factory_->CreateStream(uuid.c_str());
  if (!stream) return "";

  base_->local_streams_[uuid] = stream;
  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("streamId", MakeStr(uuid));
  return ToJson(result);
}

std::string WebrtcMediaStream::MediaStreamGetTracks(
    const std::string& stream_id) {
  scoped_refptr<RTCMediaStream> stream = base_->MediaStreamForId(stream_id);
  if (!stream) return "";

  JNode result;
  result.type = JNode::kObj;
  JNode audio_tracks;
  audio_tracks.type = JNode::kArr;
  JNode video_tracks;
  video_tracks.type = JNode::kArr;

  for (auto& track : stream->audio_tracks().std_vector()) {
    base_->local_tracks_[track->id().std_string()] = track;
    audio_tracks.arr.push_back(MakeObj({
        {"id", MakeStr(track->id().std_string())},
        {"label", MakeStr(track->id().std_string())},
        {"kind", MakeStr(track->kind().std_string())},
        {"enabled", MakeBool(track->enabled())},
        {"remote", MakeBool(true)},
        {"readyState", MakeStr("live")},
    }));
  }
  for (auto& track : stream->video_tracks().std_vector()) {
    base_->local_tracks_[track->id().std_string()] = track;
    video_tracks.arr.push_back(MakeObj({
        {"id", MakeStr(track->id().std_string())},
        {"label", MakeStr(track->id().std_string())},
        {"kind", MakeStr(track->kind().std_string())},
        {"enabled", MakeBool(track->enabled())},
        {"remote", MakeBool(true)},
        {"readyState", MakeStr("live")},
    }));
  }

  result.obj.emplace_back("audioTracks", std::move(audio_tracks));
  result.obj.emplace_back("videoTracks", std::move(video_tracks));
  return ToJson(result);
}

void WebrtcMediaStream::MediaStreamDispose(const std::string& stream_id) {
  scoped_refptr<RTCMediaStream> stream = base_->MediaStreamForId(stream_id);
  if (!stream) return;

  for (auto& track : stream->audio_tracks().std_vector()) {
    stream->RemoveTrack(track);
    base_->local_tracks_.erase(track->id().std_string());
  }
  for (auto& track : stream->video_tracks().std_vector()) {
    stream->RemoveTrack(track);
    base_->local_tracks_.erase(track->id().std_string());
    auto cap = base_->video_capturers_.find(track->id().std_string());
    if (cap != base_->video_capturers_.end()) {
      if (cap->second->CaptureStarted()) cap->second->StopCapture();
      base_->video_capturers_.erase(cap);
    }
  }
  base_->RemoveStreamForId(stream_id);
}

void WebrtcMediaStream::MediaStreamTrackDispose(const std::string& track_id) {
  for (auto& item : base_->local_streams_) {
    auto stream = item.second;
    for (auto& track : stream->audio_tracks().std_vector()) {
      if (track->id().std_string() == track_id) stream->RemoveTrack(track);
    }
    for (auto& track : stream->video_tracks().std_vector()) {
      if (track->id().std_string() == track_id) {
        stream->RemoveTrack(track);
        auto cap = base_->video_capturers_.find(track_id);
        if (cap != base_->video_capturers_.end()) {
          if (cap->second->CaptureStarted()) cap->second->StopCapture();
          base_->video_capturers_.erase(cap);
        }
      }
    }
  }
  base_->RemoveMediaTrackForId(track_id);
}

bool WebrtcMediaStream::MediaStreamAddTrack(const std::string& stream_id,
                                            const std::string& track_id) {
  scoped_refptr<RTCMediaStream> stream = base_->MediaStreamForId(stream_id);
  scoped_refptr<RTCMediaTrack> track = base_->MediaTrackForId(track_id);
  if (!stream || !track) return false;

  std::string kind = track->kind().std_string();
  if (kind == "audio") {
    return stream->AddTrack(static_cast<RTCAudioTrack*>(track.get()));
  } else if (kind == "video") {
    return stream->AddTrack(static_cast<RTCVideoTrack*>(track.get()));
  }
  return false;
}

bool WebrtcMediaStream::MediaStreamRemoveTrack(const std::string& stream_id,
                                               const std::string& track_id) {
  scoped_refptr<RTCMediaStream> stream = base_->MediaStreamForId(stream_id);
  scoped_refptr<RTCMediaTrack> track = base_->MediaTrackForId(track_id);
  if (!stream || !track) return false;

  std::string kind = track->kind().std_string();
  if (kind == "audio") {
    return stream->RemoveTrack(static_cast<RTCAudioTrack*>(track.get()));
  } else if (kind == "video") {
    return stream->RemoveTrack(static_cast<RTCVideoTrack*>(track.get()));
  }
  return false;
}

// ================= 主控/非被控录制, 无需实现 =================
// SelectAudioOutput        — 选播放设备, 主控端(观看/播放方)用
// MediaStreamTrackSetEnable— 参考 flutter 本身即 NotImplemented()
// MediaStreamTrackSwitchCamera — 参考 flutter 本身即 NotImplemented(), 移动端用
// OnDeviceChange           — 采集设备热插拔通知需全局回调面, 后续批次补

}  // namespace webrtc
