#ifndef WEBRTC_SCREEN_CAPTURE_HXX
#define WEBRTC_SCREEN_CAPTURE_HXX

/* 对应 flutter_screen_capture.h 的 FlutterScreenCapture: 桌面源列表 + getDisplayMedia。
 * 被控端采集自己屏幕发布给主控。源列表/媒体列表/捕获器状态放 WebrtcBase,
 * 便于跨调用存活(参考 base.desktop_capturer_)。 */
#include "webrtc_base.h"
#include "webrtc_common.h"

namespace webrtc {

using namespace libwebrtc;

class WebrtcScreenCapture {
 public:
  explicit WebrtcScreenCapture(WebrtcBase* base);

  // types: ["screen","window"] → {"sources":[{id,name,type,thumbnailSize}]}, 失败空串
  std::string GetDesktopSources(const JNode& types);

  // constraints: {"video":{"deviceId":{"exact":id},"mandatory":{"frameRate":n},"cursor":"never"}}
  // → {"streamId","audioTracks":[],"videoTracks":[{id,label,kind,enabled}]}, 失败空串
  std::string GetDisplayMedia(const JNode& constraints);

 private:
  bool BuildDesktopSourcesList(const JNode& types, bool force_reload);

  WebrtcBase* base_;
};

}  // namespace webrtc

#endif  // WEBRTC_SCREEN_CAPTURE_HXX
