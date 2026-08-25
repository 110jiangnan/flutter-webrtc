// webrtc_screen_capture.cc — 屏幕采集(参考 flutter_screen_capture.cc)。
// 被控端采集自己的屏幕/窗口发布给主控。

#include "webrtc_screen_capture.h"

#include "rtc_desktop_capturer.h"
#include "rtc_desktop_device.h"
#include "rtc_desktop_media_list.h"
#include "rtc_peerconnection_factory.h"

namespace webrtc {

using namespace libwebrtc;

// 源 id(如 "0",EnumDisplayDevicesW 序号/WebRTC sourceId)→ intptr 透传给外部帧回调,
// Rust 回调据此取对应屏幕的锁屏帧槽。非数字(如窗口源)视为 0。
static void* UserDataForSourceId(const std::string& source_id) {
  int idx = 0;
  try {
    idx = std::stoi(source_id);
  } catch (...) {
  }
  return reinterpret_cast<void*>(static_cast<intptr_t>(idx));
}

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

  // 注册进多源注册表(锁屏帧替换要对所有在跑的桌面采集器生效), 并记录 stream→源 映射
  // 供 MediaStreamDispose 摘除。若此前已挂过锁屏外部回调(锁屏期间新开会话), 自动带上。
  if (desktop_capturer->source().get()) {
    std::string src_id = desktop_capturer->source()->id().std_string();
    base_->desktop_capturers_[src_id] = desktop_capturer;
    base_->desktop_stream_sources_[uuid] = src_id;
    if (external_cb_ != 0) {
      desktop_capturer->SetExternalFrameCallback(
          reinterpret_cast<ExternalFrameCallback>(external_cb_),
          UserDataForSourceId(src_id));
    }
  }

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

int WebrtcScreenCapture::SetExternalFrameCallback(int64_t callback_ptr,
                                                  void* user_data) {
  // 记住最近一次回调: 之后新建的采集器(GetDisplayMedia)会自动带上,
  // 覆盖"锁屏已激活、会话随后才开启"的顺序问题。
  external_cb_ = callback_ptr;

  // 无任何在跑采集器时静默失败; 上层轮询可重试(回调已记住, 新建采集器仍会被带上)。
  if (base_->desktop_capturers_.empty()) return -1;

  ExternalFrameCallback cb =
      callback_ptr != 0 ? reinterpret_cast<ExternalFrameCallback>(callback_ptr)
                        : nullptr;
  for (auto& kv : base_->desktop_capturers_) {
    if (!kv.second.get()) continue;
    if (cb) {
      // user_data 为空时按每路采集器的源 id 自动路由(多屏各取各屏的锁屏帧);
      // 显式传入时对所有采集器统一使用(单路部署的显式覆盖)。
      void* ud = user_data ? user_data : UserDataForSourceId(kv.first);
      kv.second->SetExternalFrameCallback(cb, ud);
    } else {
      kv.second->ClearExternalFrameCallback();
    }
  }
  return 0;
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
