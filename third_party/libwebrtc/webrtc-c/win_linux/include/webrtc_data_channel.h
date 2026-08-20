#ifndef WEBRTC_DATA_CHANNEL_HXX
#define WEBRTC_DATA_CHANNEL_HXX

/* 对应 flutter_data_channel.h 的 FlutterRTCDataChannelObserver + FlutterDataChannel:
 * 被控通过 data channel 接收主控的控制命令。
 *   主控主动建 → PC 观察者 OnDataChannel 上报 didOpenDataChannel(带 flutterId)
 *   被控也可主动建 → WebrtcDataChannel::Create
 * 消息/状态事件经 SetCallback 注册的 C 回调转发给 dart。 */
#include "webrtc.h"

#include "rtc_data_channel.h"

#include "webrtc_base.h"
#include "webrtc_common.h"

namespace webrtc {

using namespace libwebrtc;

// data channel 观察者: 状态/消息事件 → C 回调
class WebrtcDataChannelObserver : public RTCDataChannelObserver {
 public:
  explicit WebrtcDataChannelObserver(
      scoped_refptr<RTCDataChannel> data_channel);
  ~WebrtcDataChannelObserver() override;

  void OnStateChange(RTCDataChannelState state) override;
  void OnMessage(const char* buffer, int length, bool binary) override;

  void SetCallback(webrtc_event_cb cb, void* ud);

  scoped_refptr<RTCDataChannel> data_channel() { return data_channel_; }

 private:
  scoped_refptr<RTCDataChannel> data_channel_;
  webrtc_event_cb cb_ = nullptr;
  void* ud_ = nullptr;
};

class WebrtcDataChannel {
 public:
  explicit WebrtcDataChannel(WebrtcBase* base);

  // 主动创建 data channel, 返回 {"id","label","flutterId"}, 失败空串
  std::string Create(webrtc_handle pc, const char* label, const JNode& init);

  // 给 data channel 注册事件回调(消息/状态)
  int SetCallback(const char* flutter_id, webrtc_event_cb cb, void* ud);

  // 发送: is_binary=0 文本 / 1 二进制
  int Send(const char* flutter_id, int is_binary, const uint8_t* data, int len);

  // 返回 {"bufferedAmount":n}
  std::string BufferedAmount(const char* flutter_id);

  // 关闭并从注册表移除
  void Close(const char* flutter_id);

 private:
  WebrtcDataChannelObserver* ObserverForId(const char* flutter_id);

  WebrtcBase* base_;
};

}  // namespace webrtc

#endif  // WEBRTC_DATA_CHANNEL_HXX
