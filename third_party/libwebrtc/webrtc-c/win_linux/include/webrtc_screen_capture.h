#ifndef WEBRTC_SCREEN_CAPTURE_HXX
#define WEBRTC_SCREEN_CAPTURE_HXX

/* 对应 flutter_screen_capture.h 的 FlutterScreenCapture: 桌面源列表 + getDisplayMedia +
 * 挂外部帧回调(SetExternalFrameCallback, 锁屏帧替换)。被控端采集自己屏幕发布给主控。
 * 源列表/媒体列表/捕获器状态放 WebrtcBase, 便于跨调用存活(参考 base.desktop_capturer_,
 * medialist_)。
 *
 * 本类实现 MediaListObserver(桌源增删/改名事件经 factory_event_cb_ 推向 dart)。
 * 缩略图像素属"渲染显示", 按需求排除。 */
#include "webrtc_base.h"
#include "webrtc_common.h"

#include "rtc_desktop_media_list.h"

namespace webrtc {

using namespace libwebrtc;

class WebrtcScreenCapture : public MediaListObserver {
 public:
  explicit WebrtcScreenCapture(WebrtcBase* base);

  // types: ["screen","window"] → {"sources":[{id,name,type,thumbnailSize}]}, 失败空串
  std::string GetDesktopSources(const JNode& types);

  // 不强制重载方式的源列表刷新(参考 UpdateDesktopSources) → {"result":true}, 失败空串
  std::string UpdateDesktopSources(const JNode& types);

  // constraints: {"video":{"deviceId":{"exact":id},"mandatory":{"frameRate":n},"cursor":"never"}}
  // → {"streamId","audioTracks":[],"videoTracks":[{id,label,kind,enabled}]}, 失败空串
  std::string GetDisplayMedia(const JNode& constraints);

  // 挂/摘外部帧回调(锁屏帧替换, 参考 flutter_screen_capture.cc)。
  // 语义: 对**所有在跑的**桌面采集器生效(base_->desktop_capturers_),每路采集器据自身
  // sourceId(EnumDisplayDevicesW 序号)把 sourceIndex 作为 user_data 透传给回调, 让 Rust
  // 侧按"每屏一路 sourceId"取对应屏幕的锁屏帧。callback_ptr 传 0 对全部采集器清除。
  // 回调指针会被记住(external_cb_), 之后新建的采集器(GetDisplayMedia)自动带上,
  // 覆盖"锁屏后新开会话"的场景。无任何采集器时返回 -1(上层轮询重试), 成功返回 0。
  int SetExternalFrameCallback(int64_t callback_ptr, void* user_data);

  // ---- MediaListObserver: 桌源变化事件推给 dart(经 factory_event_cb_) ----
  void OnMediaSourceAdded(scoped_refptr<MediaSource> source) override;
  void OnMediaSourceRemoved(scoped_refptr<MediaSource> source) override;
  void OnMediaSourceNameChanged(scoped_refptr<MediaSource> source) override;
  // 缩略图像素属"渲染显示", 不补(空实现占位派生必需)
  void OnMediaSourceThumbnailChanged(
      scoped_refptr<MediaSource> source) override;

 private:
  bool BuildDesktopSourcesList(const JNode& types, bool force_reload);

  // 往 factory 级事件回调推一条桌源事件 JSON {"event":..., "id":..., ...}
  void FireDesktopEvent(const std::string& event, const JNode& body);

  // 最近一次设置的外部帧回调指针(0 = 未挂)。新建采集器时自动复用。
  int64_t external_cb_ = 0;

  WebrtcBase* base_;
};

}  // namespace webrtc

#endif  // WEBRTC_SCREEN_CAPTURE_HXX
