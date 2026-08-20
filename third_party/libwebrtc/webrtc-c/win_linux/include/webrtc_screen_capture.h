#ifndef WEBRTC_SCREEN_CAPTURE_HXX
#define WEBRTC_SCREEN_CAPTURE_HXX

/* 对应 flutter_screen_capture.h 的 FlutterScreenCapture: 桌面源列表 + getDisplayMedia。
 * 被控端采集自己屏幕发布给主控。源列表/媒体列表/捕获器状态放 WebrtcBase,
 * 便于跨调用存活(参考 base.desktop_capturer_, medialist_)。
 *
 * 本类实现 MediaListObserver(桌源增删/改名事件经 factory_event_cb_ 推向 dart)。
 * 渲染相关(缩略图像素/外部帧回调)按需求排除。 */
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

  WebrtcBase* base_;
};

}  // namespace webrtc

#endif  // WEBRTC_SCREEN_CAPTURE_HXX
