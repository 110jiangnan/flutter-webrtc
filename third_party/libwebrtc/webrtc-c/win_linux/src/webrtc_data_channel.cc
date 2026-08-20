#include "webrtc_data_channel.h"

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
}

void WebrtcDataChannelObserver::OnStateChange(RTCDataChannelState state) {
  if (!cb_) return;
  std::string json = ToJson(MakeObj({
      {"event", MakeStr("dataChannelStateChanged")},
      {"id", MakeNum(data_channel_->id())},
      {"state", MakeStr(DataStateString(state))},
  }));
  cb_(ud_, json.c_str(), nullptr, 0);
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
  cb_(ud_, json.c_str(),
      binary ? reinterpret_cast<const uint8_t*>(buffer) : nullptr,
      binary ? length : 0);
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
