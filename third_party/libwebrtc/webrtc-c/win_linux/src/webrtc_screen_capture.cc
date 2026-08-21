// webrtc_screen_capture.cc — 屏幕采集(参考 flutter_screen_capture.cc)。
// 被控端采集自己的屏幕/窗口发布给主控。

#include "webrtc_screen_capture.h"

#include "rtc_desktop_capturer.h"
#include "rtc_desktop_device.h"
#include "rtc_desktop_media_list.h"
#include "rtc_peerconnection_factory.h"

namespace webrtc {

using namespace libwebrtc;

WebrtcScreenCapture::WebrtcScreenCapture(WebrtcBase* base) : base_(base) {}

bool WebrtcScreenCapture::BuildDesktopSourcesList(const JNode& types,
                                                  bool force_reload) {
  base_->desktop_sources_.clear();
  if (types.type != JNode::kArr) return false;

  for (auto& t : types.arr) {
    if (t.type != JNode::kStr) return false;
    std::string type_str = t.s;
    DesktopType desktop_type = kScreen;
    if (type_str == "screen") {
      desktop_type = kScreen;
    } else if (type_str == "window") {
      desktop_type = kWindow;
    } else {
      return false;
    }

    scoped_refptr<RTCDesktopMediaList> source_list;
    auto it = base_->desktop_medialist_.find(desktop_type);
    if (it != base_->desktop_medialist_.end()) {
      source_list = it->second;
    } else {
      source_list = base_->desktop_device_->GetDesktopMediaList(desktop_type);
      // 常驻 observer 才能在列表生命周期内收到增删/改名事件(参考 RegisterMediaListObserver)
      source_list->RegisterMediaListObserver(this);
      base_->desktop_medialist_[desktop_type] = source_list;
    }
    source_list->UpdateSourceList(force_reload);
    int count = source_list->GetSourceCount();
    for (int j = 0; j < count; j++) {
      base_->desktop_sources_.push_back(source_list->GetSource(j));
    }
  }
  return true;
}

std::string WebrtcScreenCapture::GetDesktopSources(const JNode& types) {
  if (!BuildDesktopSourcesList(types, true)) return "";

  JNode list;
  list.type = JNode::kArr;
  for (auto& source : base_->desktop_sources_) {
    list.arr.push_back(MakeObj({
        {"id", MakeStr(source->id().std_string())},
        {"name", MakeStr(source->name().std_string())},
        {"type", MakeStr(source->type() == kWindow ? "window" : "screen")},
        {"thumbnailSize", MakeObj({{"width", MakeNum(0)},
                                   {"height", MakeNum(0)}})},
    }));
  }
  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("sources", std::move(list));
  return ToJson(result);
}

std::string WebrtcScreenCapture::UpdateDesktopSources(const JNode& types) {
  // 参考 UpdateDesktopSources: 不强制重载(force_reload=false), 返回 {"result":true}
  if (!BuildDesktopSourcesList(types, false)) return "";
  return ToJson(MakeObj({{"result", MakeBool(true)}}));
}

std::string WebrtcScreenCapture::GetDisplayMedia(const JNode& constraints) {
  std::string source_id = "0";
  double fps = 30.0;
  bool show_cursor = true;

  const JNode* video = constraints.Get("video");
  if (video && video->type == JNode::kObj) {
    const JNode* device_id = video->Get("deviceId");
    if (device_id && device_id->type == JNode::kObj) {
      source_id = device_id->StrOf("exact");
      if (source_id.empty()) return "";
    }
    const JNode* mandatory = video->Get("mandatory");
    if (mandatory && mandatory->type == JNode::kObj) {
      const JNode* frame_rate = mandatory->Get("frameRate");
      if (frame_rate && frame_rate->type == JNode::kNum && frame_rate->n != 0.0) {
        fps = frame_rate->n;
      }
    }
    std::string cursor = video->StrOf("cursor");
    if (!cursor.empty() && cursor == "never") show_cursor = false;
  }

  // 源列表为空时先构建(默认 screen + window), 保证 getDisplayMedia 可独立调用
  if (base_->desktop_sources_.empty()) {
    JNode types;
    types.type = JNode::kArr;
    types.arr.push_back(MakeStr("screen"));
    types.arr.push_back(MakeStr("window"));
    BuildDesktopSourcesList(types, true);
  }

  scoped_refptr<MediaSource> source;
  for (auto& src : base_->desktop_sources_) {
    if (src->id().std_string() == source_id) source = src;
  }
  if (!source) return "";

  std::string uuid = base_->GenerateUUID();
  scoped_refptr<RTCMediaStream> stream =
      base_->factory_->CreateStream(uuid.c_str());
  if (!stream) return "";

  scoped_refptr<RTCDesktopCapturer> desktop_capturer =
      base_->desktop_device_->CreateDesktopCapturer(source, show_cursor);
  if (!desktop_capturer) return "";
  base_->desktop_capturer_ = desktop_capturer;

  JNode video_constraints;
  if (video && video->type == JNode::kObj) video_constraints = *video;
  scoped_refptr<RTCVideoSource> video_source =
      base_->factory_->CreateDesktopSource(
          desktop_capturer, "screen_capture_input",
          base_->ParseMediaConstraints(video_constraints));
  if (!video_source) return "";

  scoped_refptr<RTCVideoTrack> track =
      base_->factory_->CreateVideoTrack(video_source, uuid.c_str());
  if (!track) return "";

  stream->AddTrack(track);
  base_->local_tracks_[track->id().std_string()] = track;
  base_->local_streams_[uuid] = stream;
  desktop_capturer->Start(uint32_t(fps));

  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("streamId", MakeStr(uuid));
  JNode audio_tracks;
  audio_tracks.type = JNode::kArr;
  result.obj.emplace_back("audioTracks", std::move(audio_tracks));
  JNode video_tracks;
  video_tracks.type = JNode::kArr;
  video_tracks.arr.push_back(MakeObj({
      {"id", MakeStr(track->id().std_string())},
      {"label", MakeStr(track->id().std_string())},
      {"kind", MakeStr("video")},
      {"enabled", MakeBool(track->enabled())},
  }));
  result.obj.emplace_back("videoTracks", std::move(video_tracks));
  return ToJson(result);
}

// ================= MediaListObserver: 桌源变化事件(对齐 flutter_screen_capture.cc) =================

void WebrtcScreenCapture::FireDesktopEvent(const std::string& event,
                                           const JNode& body) {
  if (!base_->factory_event_cb_) return;
  JNode evt;
  evt.type = JNode::kObj;
  evt.obj.emplace_back("event", MakeStr(event));
  for (auto& kv : body.obj) evt.obj.push_back(kv);
  std::string json = ToJson(evt);
  base_->factory_event_cb_(base_->factory_event_ud_, StrDup(json), nullptr, 0);
}

void WebrtcScreenCapture::OnMediaSourceAdded(scoped_refptr<MediaSource> source) {
  FireDesktopEvent("desktopSourceAdded", MakeObj({
      {"id", MakeStr(source->id().std_string())},
      {"name", MakeStr(source->name().std_string())},
      {"type", MakeStr(source->type() == kWindow ? "window" : "screen")},
      {"thumbnailSize", MakeObj({{"width", MakeNum(0)}, {"height", MakeNum(0)}})},
  }));
}

void WebrtcScreenCapture::OnMediaSourceRemoved(scoped_refptr<MediaSource> source) {
  FireDesktopEvent("desktopSourceRemoved",
                   MakeObj({{"id", MakeStr(source->id().std_string())}}));
}

void WebrtcScreenCapture::OnMediaSourceNameChanged(
    scoped_refptr<MediaSource> source) {
  FireDesktopEvent("desktopSourceNameChanged", MakeObj({
      {"id", MakeStr(source->id().std_string())},
      {"name", MakeStr(source->name().std_string())},
  }));
}

void WebrtcScreenCapture::OnMediaSourceThumbnailChanged(
    scoped_refptr<MediaSource> source) {
  // 缩略图像素属"渲染显示", 排除(空实现占位派生必需)
}

}  // namespace webrtc
