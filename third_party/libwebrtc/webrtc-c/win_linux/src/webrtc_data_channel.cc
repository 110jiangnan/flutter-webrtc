#include "webrtc_data_channel.h"

#include <cstring>

#include "rtc_data_channel.h"

#include "webrtc_peerconnection.h"

namespace webrtc {

using namespace libwebrtc;

static const char* DataStateString(RTCDataChannelState state) {
  switch (state) {
    case RTCDataChannelConnecting: return "connecting";
    case RTCDataChannelOpen: return "open";
    case RTCDataChannelClosing: return "closing";
    case RTCDataChannelClosed: return "closed";
  }
  return "";
}

WebrtcDataChannelObserver::WebrtcDataChannelObserver(
    scoped_refptr<RTCDataChannel> data_channel)
    : data_channel_(data_channel) {
  data_channel_->RegisterObserver(this);
}

WebrtcDataChannelObserver::~WebrtcDataChannelObserver() {
  if (data_channel_) {
    data_channel_->UnregisterObserver();
  }
}

void WebrtcDataChannelObserver::SetCallback(webrtc_event_cb cb, void* ud) {
  cb_ = cb;
  ud_ = ud;
  // 远端通道可能在 Dart attach()(即本函数)注册回调之前就已 Open, 那次
  // OnStateChange 事件会因 cb_==null 被丢; 这里仅在已 Open 时补发一次。
  // 事件经 NativeCallable 异步编组回 Dart, 会比 didOpenDataChannel 的
  // onDataChannel 回调晚到, 应用层 handler 此时已就位。本地通道此刻还是
  // connecting/closed, 不会命中 Open 分支, 等真实状态事件即可。
  if (cb_ && data_channel_->state() == RTCDataChannelOpen) {
    OnStateChange(RTCDataChannelOpen);
  }
}

void WebrtcDataChannelObserver::OnStateChange(RTCDataChannelState state) {
  if (!cb_) return;
  std::string json = ToJson(MakeObj({
      {"event", MakeStr("dataChannelStateChanged")},
      {"id", MakeNum(data_channel_->id())},
      {"state", MakeStr(DataStateString(state))},
  }));
  // 异步回调: 栈上字符串会被回收, 传堆拷贝, Dart 侧 webrtc_free_string 释放
  cb_(ud_, StrDup(json), nullptr, 0);
}

void WebrtcDataChannelObserver::OnMessage(const char* buffer, int length,
                                          bool binary) {
  if (!cb_) return;
  std::string json = ToJson(MakeObj({
      {"event", MakeStr("dataChannelReceiveMessage")},
      {"id", MakeNum(data_channel_->id())},
      {"type", MakeStr(binary ? "binary" : "text")},
      {"data", MakeStr(binary ? "" : std::string(buffer, length))},
  }));
  // json 和 binary 都要堆拷贝: 回调从 webrtc 线程异步编组到 Dart isolate 时才执行,
  // 届时源 buffer 已失效。Dart 侧读后统一 webrtc_free_string 释放。
  uint8_t* binary_copy = nullptr;
  if (binary && length > 0) {
    binary_copy = static_cast<uint8_t*>(malloc(length));
    memcpy(binary_copy, buffer, length);
  }
  cb_(ud_, StrDup(json),
      binary_copy,
      binary && length > 0 ? length : 0);
}

WebrtcDataChannel::WebrtcDataChannel(WebrtcBase* base) : base_(base) {}

WebrtcDataChannelObserver* WebrtcDataChannel::ObserverForId(
    const char* flutter_id) {
  if (!flutter_id) return nullptr;
  base_->lock();
  auto it = base_->data_channel_observers_.find(flutter_id);
  WebrtcDataChannelObserver* obs =
      it != base_->data_channel_observers_.end() ? it->second.get() : nullptr;
  base_->unlock();
  return obs;
}

scoped_refptr<RTCDataChannel> WebrtcDataChannel::DataChannelForId(
    const char* flutter_id) {
  if (!flutter_id) return nullptr;
  base_->lock();
  auto it = base_->data_channel_observers_.find(flutter_id);
  scoped_refptr<RTCDataChannel> dc =
      it != base_->data_channel_observers_.end() ? it->second->data_channel()
                                                 : nullptr;
  base_->unlock();
  return dc;
}

std::string WebrtcDataChannel::Create(webrtc_handle pc, const char* label,
                                      const JNode& init) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !label) return "";

  RTCDataChannelInit channel_init;
  const JNode* id = init.Get("id");
  if (id && id->type == JNode::kNum) channel_init.id = static_cast<int>(id->n);
  const JNode* ordered = init.Get("ordered");
  if (ordered && ordered->type == JNode::kBool) channel_init.ordered = ordered->b;
  const JNode* max_retransmits = init.Get("maxRetransmits");
  if (max_retransmits && max_retransmits->type == JNode::kNum)
    channel_init.maxRetransmits = static_cast<int>(max_retransmits->n);
  const JNode* negotiated = init.Get("negotiated");
  if (negotiated && negotiated->type == JNode::kBool)
    channel_init.negotiated = negotiated->b;
  const JNode* protocol = init.Get("protocol");
  if (protocol && protocol->type == JNode::kStr)
    channel_init.protocol = protocol->s;  // 参考未解析 reliable, 保持默认 true

  scoped_refptr<RTCDataChannel> data_channel =
      h->pc->CreateDataChannel(label, &channel_init);
  if (!data_channel) return "";

  std::string uuid = base_->GenerateUUID();
  auto observer = std::make_unique<WebrtcDataChannelObserver>(data_channel);
  base_->lock();
  base_->data_channel_observers_[uuid] = std::move(observer);
  base_->unlock();

  return ToJson(MakeObj({{"id", MakeNum(data_channel->id())},
                         {"label", MakeStr(data_channel->label().std_string())},
                         {"flutterId", MakeStr(uuid)}}));
}

int WebrtcDataChannel::SetCallback(const char* flutter_id, webrtc_event_cb cb,
                                   void* ud) {
  WebrtcDataChannelObserver* observer = ObserverForId(flutter_id);
  if (!observer) return -1;
  observer->SetCallback(cb, ud);
  return 0;
}

int WebrtcDataChannel::Send(const char* flutter_id, int is_binary,
                            const uint8_t* data, int len) {
  if (!data || len < 0) return -1;
  scoped_refptr<RTCDataChannel> dc = DataChannelForId(flutter_id);
  if (!dc) return -1;
  dc->Send(data, static_cast<uint32_t>(len), is_binary != 0);
  return 0;
}

std::string WebrtcDataChannel::BufferedAmount(const char* flutter_id) {
  scoped_refptr<RTCDataChannel> dc = DataChannelForId(flutter_id);
  if (!dc) return "";
  return ToJson(MakeObj(
      {{"bufferedAmount",
        MakeNum(static_cast<double>(dc->buffered_amount()))}}));
}

void WebrtcDataChannel::Close(const char* flutter_id) {
  if (!flutter_id) return;
  std::unique_ptr<WebrtcDataChannelObserver> observer;
  base_->lock();
  auto it = base_->data_channel_observers_.find(flutter_id);
  if (it != base_->data_channel_observers_.end()) {
    observer = std::move(it->second);
    base_->data_channel_observers_.erase(it);
  }
  base_->unlock();
  if (!observer) return;
  observer->data_channel()->Close();
}

}  // namespace webrtc
