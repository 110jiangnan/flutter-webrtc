#include "webrtc_peerconnection.h"

#include <cstring>

#include "rtc_dtmf_sender.h"
#include "rtc_ice_candidate.h"
#include "rtc_peerconnection.h"
#include "rtc_rtp_parameters.h"
#include "rtc_rtp_receiver.h"
#include "rtc_rtp_sender.h"
#include "rtc_rtp_transceiver.h"
#include "rtc_session_description.h"

#include "webrtc_data_channel.h"

namespace webrtc {

using namespace libwebrtc;

namespace {

// ================= 状态/方向 → 字符串(和 flutter_peerconnection.cc 一致) =================

std::string RTCMediaTypeToString(RTCMediaType type) {
  switch (type) {
    case RTCMediaType::AUDIO: return "audio";
    case RTCMediaType::VIDEO: return "video";
    case RTCMediaType::DATA: return "data";
    case RTCMediaType::UNSUPPORTED: return "unsupported";
  }
  return "";
}

std::string TransceiverDirectionString(RTCRtpTransceiverDirection direction) {
  switch (direction) {
    case RTCRtpTransceiverDirection::kSendRecv: return "sendrecv";
    case RTCRtpTransceiverDirection::kSendOnly: return "sendonly";
    case RTCRtpTransceiverDirection::kRecvOnly: return "recvonly";
    case RTCRtpTransceiverDirection::kInactive: return "inactive";
    case RTCRtpTransceiverDirection::kStopped: return "stoped";
  }
  return "";
}

const char* IceConnectionStateString(RTCIceConnectionState state) {
  static const char* k[] = {"new", "checking", "completed", "connected",
                            "failed", "disconnected", "closed", "statemax"};
  return k[state];
}
const char* PeerConnectionStateString(RTCPeerConnectionState state) {
  static const char* k[] = {"new", "connecting", "connected", "disconnected",
                            "failed", "closed"};
  return k[state];
}
const char* IceGatheringStateString(RTCIceGatheringState state) {
  static const char* k[] = {"new", "gathering", "complete"};
  return k[state];
}
const char* SignalingStateString(RTCSignalingState state) {
  static const char* k[] = {"stable", "have-local-offer", "have-remote-offer",
                            "have-local-pranswer", "have-remote-pranswer",
                            "closed"};
  return k[state];
}

// ================= JSON 序列化(键名对齐 flutter_peerconnection.cc 的 toMap) =================

JNode MediaTrackToJNode(RTCMediaTrack* track) {
  JNode info;
  if (!track) return info;
  info = MakeObj({
      {"id", MakeStr(track->id().std_string())},
      {"kind", MakeStr(track->kind().std_string())},
      {"enabled", MakeBool(track->enabled())},
  });
  const char* state =
      track->state() == RTCMediaTrack::kLive ? "live" : "ended";
  std::string kind = track->kind().std_string();
  if (kind == "video") {
    info.obj.emplace_back("readyState", MakeStr(state));
    info.obj.emplace_back("label", MakeStr("video"));
  } else if (kind == "audio") {
    info.obj.emplace_back("readyState", MakeStr(state));
    info.obj.emplace_back("label", MakeStr("audio"));
  }
  return info;
}

JNode RtpParametersToJNode(RTCRtpParameters* params) {
  JNode info;
  info.type = JNode::kObj;
  info.obj.emplace_back(
      "transactionId", MakeStr(params->transaction_id().std_string()));

  JNode rtcp = MakeObj({
      {"cname", MakeStr(params->rtcp_parameters()->cname().std_string())},
      {"reducedSize", MakeBool(params->rtcp_parameters()->reduced_size())},
  });
  info.obj.emplace_back("rtcp", std::move(rtcp));

  JNode header_extensions;
  header_extensions.type = JNode::kArr;
  for (auto& ext : params->header_extensions().std_vector()) {
    header_extensions.arr.push_back(MakeObj({
        {"uri", MakeStr(ext->uri().std_string())},
        {"id", MakeNum(ext->id())},
        {"encrypted", MakeBool(ext->encrypt())},
    }));
  }
  info.obj.emplace_back("headerExtensions", std::move(header_extensions));

  JNode encodings;
  encodings.type = JNode::kArr;
  for (auto& enc : params->encodings().std_vector()) {
    encodings.arr.push_back(MakeObj({
        {"active", MakeBool(enc->active())},
        {"maxBitrate", MakeNum(enc->max_bitrate_bps())},
        {"minBitrate", MakeNum(enc->min_bitrate_bps())},
        {"maxFramerate", MakeNum(enc->max_framerate())},
        {"scaleResolutionDownBy", MakeNum(enc->scale_resolution_down_by())},
        {"scalabilityMode", MakeStr(enc->scalability_mode().std_string())},
        {"ssrc", MakeNum(static_cast<int>(enc->ssrc()))},
    }));
  }
  info.obj.emplace_back("encodings", std::move(encodings));

  JNode codecs;
  codecs.type = JNode::kArr;
  for (auto& codec : params->codecs().std_vector()) {
    JNode param_map;
    param_map.type = JNode::kObj;
    for (auto& item : codec->parameters().std_vector())
      param_map.obj.emplace_back(item.first.std_string(),
                                 MakeStr(item.second.std_string()));
    codecs.arr.push_back(MakeObj({
        {"name", MakeStr(codec->name().std_string())},
        {"payloadType", MakeNum(codec->payload_type())},
        {"clockRate", MakeNum(codec->clock_rate())},
        {"numChannels", MakeNum(codec->num_channels())},
        {"parameters", std::move(param_map)},
        {"kind", MakeStr(RTCMediaTypeToString(codec->kind()))},
    }));
  }
  info.obj.emplace_back("codecs", std::move(codecs));

  switch (params->GetDegradationPreference()) {
    case RTCDegradationPreference::MAINTAIN_FRAMERATE:
      info.obj.emplace_back("degradationPreference", MakeStr("maintain-framerate"));
      break;
    case RTCDegradationPreference::MAINTAIN_RESOLUTION:
      info.obj.emplace_back("degradationPreference", MakeStr("maintain-resolution"));
      break;
    case RTCDegradationPreference::BALANCED:
      info.obj.emplace_back("degradationPreference", MakeStr("balanced"));
      break;
    case RTCDegradationPreference::DISABLED:
      info.obj.emplace_back("degradationPreference", MakeStr("disabled"));
      break;
  }
  return info;
}

JNode DtmfSenderToJNode(RTCDtmfSender* dtmf, const std::string& id) {
  JNode info;
  info.type = JNode::kObj;
  if (dtmf) {
    info.obj.emplace_back("dtmfSenderId", MakeStr(id));
    info.obj.emplace_back("interToneGap", MakeNum(dtmf->inter_tone_gap()));
    info.obj.emplace_back("duration", MakeNum(dtmf->duration()));
  }
  return info;
}

JNode RtpSenderToJNode(RTCRtpSender* sender) {
  std::string id = sender->id().std_string();
  return MakeObj({
      {"senderId", MakeStr(id)},
      {"ownsTrack", MakeBool(true)},
      {"dtmfSender", DtmfSenderToJNode(sender->dtmf_sender().get(), id)},
      {"rtpParameters", RtpParametersToJNode(sender->parameters().get())},
      {"track", MediaTrackToJNode(sender->track().get())},
  });
}

JNode RtpReceiverToJNode(RTCRtpReceiver* receiver) {
  return MakeObj({
      {"receiverId", MakeStr(receiver->id().std_string())},
      {"rtpParameters", RtpParametersToJNode(receiver->parameters().get())},
      {"track", MediaTrackToJNode(receiver->track().get())},
  });
}

JNode TransceiverToJNode(RTCRtpTransceiver* transceiver) {
  return MakeObj({
      {"transceiverId", MakeStr(transceiver->transceiver_id().std_string())},
      {"mid", MakeStr(transceiver->mid().std_string())},
      {"direction", MakeStr(TransceiverDirectionString(transceiver->direction()))},
      {"sender", RtpSenderToJNode(transceiver->sender().get())},
      {"receiver", RtpReceiverToJNode(transceiver->receiver().get())},
  });
}

JNode MediaStreamToJNode(RTCMediaStream* stream) {
  JNode params = MakeObj({
      {"streamId", MakeStr(stream->id().std_string())},
      {"ownerTag", MakeStr("")},
  });
  JNode audio_tracks;
  audio_tracks.type = JNode::kArr;
  for (auto& track : stream->audio_tracks().std_vector())
    audio_tracks.arr.push_back(MediaTrackToJNode(track.get()));
  params.obj.emplace_back("audioTracks", std::move(audio_tracks));
  JNode video_tracks;
  video_tracks.type = JNode::kArr;
  for (auto& track : stream->video_tracks().std_vector())
    video_tracks.arr.push_back(MediaTrackToJNode(track.get()));
  params.obj.emplace_back("videoTracks", std::move(video_tracks));
  return params;
}

JNode StatsToJNode(MediaRTCStats* stats) {
  JNode values;
  values.type = JNode::kObj;
  for (auto& member : stats->Members().std_vector()) {
    const std::string name = member->GetName().std_string();
    switch (member->GetType()) {
      case RTCStatsMember::kBool:
        values.obj.emplace_back(name, MakeBool(member->ValueBool()));
        break;
      case RTCStatsMember::kInt32:
        values.obj.emplace_back(name, MakeNum(member->ValueInt32()));
        break;
      case RTCStatsMember::kUint32:
        values.obj.emplace_back(name, MakeNum(static_cast<int64_t>(member->ValueUint32())));
        break;
      case RTCStatsMember::kInt64:
        values.obj.emplace_back(name, MakeNum(static_cast<double>(member->ValueInt64())));
        break;
      case RTCStatsMember::kUint64:
        values.obj.emplace_back(name, MakeNum(static_cast<double>(member->ValueUint64())));
        break;
      case RTCStatsMember::kDouble:
        values.obj.emplace_back(name, MakeNum(member->ValueDouble()));
        break;
      case RTCStatsMember::kString:
        values.obj.emplace_back(name, MakeStr(member->ValueString().std_string()));
        break;
      default:
        break;
    }
  }
  return MakeObj({
      {"id", MakeStr(stats->id().std_string())},
      {"type", MakeStr(stats->type().std_string())},
      {"timestamp", MakeNum(static_cast<double>(stats->timestamp_us()))},
      {"values", std::move(values)},
  });
}

// ================= 内部工具 =================

scoped_refptr<RTCRtpSender> FindSenderById(PcHandle* h, const std::string& id) {
  for (auto& sender : h->pc->senders().std_vector()) {
    if (sender->id().std_string() == id) return sender;
  }
  return nullptr;
}

scoped_refptr<RTCRtpTransceiver> FindTransceiverById(PcHandle* h,
                                                     const std::string& id) {
  for (auto& transceiver : h->pc->transceivers().std_vector()) {
    if (transceiver->transceiver_id().std_string() == id) return transceiver;
  }
  return nullptr;
}

// 用 JSON 里的 encodings/degradationPreference 更新 RTCRtpParameters(参考 updateRtpParameters)
void UpdateRtpParameters(const JNode& json,
                         scoped_refptr<RTCRtpParameters> parameters) {
  const JNode* encodings = json.Get("encodings");
  if (encodings && encodings->type == JNode::kArr) {
    auto params_encodings = parameters->encodings().std_vector();
    size_t idx = 0;
    for (auto& param : params_encodings) {
      if (idx >= encodings->arr.size()) break;
      const JNode& map = encodings->arr[idx];
      if (map.type != JNode::kObj) { ++idx; continue; }
      const JNode* active = map.Get("active");
      if (active && active->type == JNode::kBool) param->set_active(active->b);
      const JNode* rid = map.Get("rid");
      if (rid && rid->type == JNode::kStr) param->set_rid(rid->s.c_str());
      const JNode* ssrc = map.Get("ssrc");
      if (ssrc && ssrc->type == JNode::kNum) param->set_ssrc(static_cast<int>(ssrc->n));
      const JNode* max_bitrate = map.Get("maxBitrate");
      if (max_bitrate && max_bitrate->type == JNode::kNum)
        param->set_max_bitrate_bps(static_cast<int>(max_bitrate->n));
      const JNode* min_bitrate = map.Get("minBitrate");
      if (min_bitrate && min_bitrate->type == JNode::kNum)
        param->set_min_bitrate_bps(static_cast<int>(min_bitrate->n));
      const JNode* max_framerate = map.Get("maxFramerate");
      if (max_framerate && max_framerate->type == JNode::kNum)
        param->set_max_framerate(max_framerate->n);
      const JNode* num_temporal = map.Get("numTemporalLayers");
      if (num_temporal && num_temporal->type == JNode::kNum)
        param->set_num_temporal_layers(static_cast<int>(num_temporal->n));
      const JNode* scale = map.Get("scaleResolutionDownBy");
      if (scale && scale->type == JNode::kNum) param->set_scale_resolution_down_by(scale->n);
      const JNode* scalability = map.Get("scalabilityMode");
      if (scalability && scalability->type == JNode::kStr)
        param->set_scalability_mode(scalability->s.c_str());
      ++idx;
    }
  }

  const JNode* degradation = json.Get("degradationPreference");
  if (degradation && degradation->type == JNode::kStr) {
    if (degradation->s == "maintain-framerate")
      parameters->SetDegradationPreference(RTCDegradationPreference::MAINTAIN_FRAMERATE);
    else if (degradation->s == "maintain-resolution")
      parameters->SetDegradationPreference(RTCDegradationPreference::MAINTAIN_RESOLUTION);
    else if (degradation->s == "disabled")
      parameters->SetDegradationPreference(RTCDegradationPreference::DISABLED);
    else if (degradation->s == "balanced")
      parameters->SetDegradationPreference(RTCDegradationPreference::BALANCED);
  }
}

}  // namespace

// ================= 观察者定义(事件格式对齐 flutter_peerconnection.cc) =================

void CppPcObserver::Fire(const std::string& event, const JNode& body) {
  if (!cb_) return;
  JNode evt;
  evt.type = JNode::kObj;
  evt.obj.emplace_back("event", MakeStr(event));
  for (auto& kv : body.obj) evt.obj.push_back(kv);
  std::string json = ToJson(evt);
  cb_(ud_, json.c_str());
}

void CppPcObserver::OnIceCandidate(scoped_refptr<RTCIceCandidate> candidate) {
  JNode c = MakeObj({{"candidate", MakeStr(candidate->candidate().std_string())},
                     {"sdpMLineIndex", MakeNum(candidate->sdp_mline_index())},
                     {"sdpMid", MakeStr(candidate->sdp_mid().std_string())}});
  Fire("onCandidate", MakeObj({{"candidate", std::move(c)}}));
}
void CppPcObserver::OnIceConnectionState(RTCIceConnectionState state) {
  Fire("iceConnectionState",
       MakeObj({{"state", MakeStr(IceConnectionStateString(state))}}));
}
void CppPcObserver::OnPeerConnectionState(RTCPeerConnectionState state) {
  Fire("peerConnectionState",
       MakeObj({{"state", MakeStr(PeerConnectionStateString(state))}}));
}
void CppPcObserver::OnIceGatheringState(RTCIceGatheringState state) {
  Fire("iceGatheringState",
       MakeObj({{"state", MakeStr(IceGatheringStateString(state))}}));
}
void CppPcObserver::OnSignalingState(RTCSignalingState state) {
  Fire("signalingState",
       MakeObj({{"state", MakeStr(SignalingStateString(state))}}));
}

void CppPcObserver::OnAddStream(scoped_refptr<RTCMediaStream> stream) {
  std::string stream_id = stream->id().std_string();
  JNode body = MakeObj({{"streamId", MakeStr(stream_id)}});

  JNode audio_tracks;
  audio_tracks.type = JNode::kArr;
  for (auto& track : stream->audio_tracks().std_vector()) {
    audio_tracks.arr.push_back(MakeObj({
        {"id", MakeStr(track->id().std_string())},
        {"label", MakeStr(track->id().std_string())},
        {"kind", MakeStr("audio")},
        {"enabled", MakeBool(track->enabled())},
        {"remote", MakeBool(true)},
        {"readyState", MakeStr("live")},
    }));
  }
  body.obj.emplace_back("audioTracks", std::move(audio_tracks));

  JNode video_tracks;
  video_tracks.type = JNode::kArr;
  for (auto& track : stream->video_tracks().std_vector()) {
    video_tracks.arr.push_back(MakeObj({
        {"id", MakeStr(track->id().std_string())},
        {"label", MakeStr(track->id().std_string())},
        {"kind", MakeStr("video")},
        {"enabled", MakeBool(track->enabled())},
        {"remote", MakeBool(true)},
        {"readyState", MakeStr("live")},
    }));
  }
  remote_streams_[stream_id] = stream;
  body.obj.emplace_back("videoTracks", std::move(video_tracks));
  Fire("onAddStream", body);
}

void CppPcObserver::OnRemoveStream(scoped_refptr<RTCMediaStream> stream) {
  Fire("onRemoveStream",
       MakeObj({{"streamId", MakeStr(stream->label().std_string())}}));
}

void CppPcObserver::OnTrack(scoped_refptr<RTCRtpTransceiver> transceiver) {
  auto receiver = transceiver->receiver();
  JNode streams_info;
  streams_info.type = JNode::kArr;
  for (auto& item : receiver->streams().std_vector())
    streams_info.arr.push_back(MediaStreamToJNode(item.get()));
  Fire("onTrack", MakeObj({
                       {"streams", std::move(streams_info)},
                       {"track", MediaTrackToJNode(receiver->track().get())},
                       {"receiver", RtpReceiverToJNode(receiver.get())},
                       {"transceiver", TransceiverToJNode(transceiver.get())},
                   }));
}

void CppPcObserver::OnAddTrack(vector<scoped_refptr<RTCMediaStream>> streams,
                               scoped_refptr<RTCRtpReceiver> receiver) {
  auto track = receiver->track();
  for (auto& stream : streams.std_vector()) {
    JNode t = MakeObj({
        {"id", MakeStr(track->id().std_string())},
        {"label", MakeStr(track->id().std_string())},
        {"kind", MakeStr(track->kind().std_string())},
        {"enabled", MakeBool(track->enabled())},
        {"remote", MakeBool(true)},
        {"readyState", MakeStr("live")},
    });
    Fire("onAddTrack", MakeObj({
                           {"streamId", MakeStr(stream->label().std_string())},
                           {"trackId", MakeStr(track->id().std_string())},
                           {"track", std::move(t)},
                       }));
  }
}

void CppPcObserver::OnRemoveTrack(scoped_refptr<RTCRtpReceiver> receiver) {
  auto track = receiver->track();
  Fire("onRemoveTrack", MakeObj({
                            {"trackId", MakeStr(track->id().std_string())},
                            {"track", MediaTrackToJNode(track.get())},
                            {"receiver", RtpReceiverToJNode(receiver.get())},
                        }));
}

// 被控: 主控发起的 data channel(控制命令), 建观察者 + 上报 didOpenDataChannel
void CppPcObserver::OnDataChannel(scoped_refptr<RTCDataChannel> data_channel) {
  if (!base_) return;
  int channel_id = data_channel->id();
  std::string uuid = base_->GenerateUUID();

  auto observer = std::make_unique<WebrtcDataChannelObserver>(data_channel);
  base_->lock();
  base_->data_channel_observers_[uuid] = std::move(observer);
  base_->unlock();

  Fire("didOpenDataChannel", MakeObj({
                                 {"id", MakeNum(channel_id)},
                                 {"label", MakeStr(data_channel->label().std_string())},
                                 {"flutterId", MakeStr(uuid)},
                             }));
}

void CppPcObserver::OnRenegotiationNeeded() {
  Fire("onRenegotiationNeeded", MakeObj({}));
}

scoped_refptr<RTCMediaStream> CppPcObserver::MediaStreamForId(
    const std::string& id) {
  auto it = remote_streams_.find(id);
  return it != remote_streams_.end() ? it->second : nullptr;
}

scoped_refptr<RTCMediaTrack> CppPcObserver::MediaTrackForId(
    const std::string& id) {
  for (auto& kv : remote_streams_) {
    auto stream = kv.second;
    for (auto& track : stream->audio_tracks().std_vector())
      if (track->id().std_string() == id) return track;
    for (auto& track : stream->video_tracks().std_vector())
      if (track->id().std_string() == id) return track;
  }
  return nullptr;
}

void CppPcObserver::RemoveStreamForId(const std::string& id) {
  remote_streams_.erase(id);
}

WebrtcPeerConnection::WebrtcPeerConnection(WebrtcBase* base) : base_(base) {}

webrtc_handle WebrtcPeerConnection::Create(const JNode& configuration,
                                           const JNode& constraints,
                                           webrtc_event_cb on_event,
                                           void* user_data) {
  base_->ParseRTCConfiguration(configuration, base_->configuration_);
  scoped_refptr<RTCMediaConstraints> media_constraints =
      base_->ParseMediaConstraints(constraints);

  // 系统音频连接用 empty_adm_factory_(参考 CreateRTCPeerConnection 的 isSysAudio)
  auto fac = base_->factory_;
  const JNode* is_sys_audio = configuration.Get("isSysAudio");
  if (is_sys_audio && is_sys_audio->type == JNode::kBool && is_sys_audio->b) {
    fac = base_->empty_adm_factory_;
  }

  scoped_refptr<RTCPeerConnection> pc =
      fac->Create(base_->configuration_, media_constraints);
  if (!pc) return nullptr;

  auto* h = new PcHandle();
  h->base = base_;
  h->observer.base_ = base_;
  h->observer.cb_ = on_event;
  h->observer.ud_ = user_data;
  h->pc = pc;
  pc->RegisterRTCPeerConnectionObserver(&h->observer);
  return h;
}

// ================= 被控: answer 流程 =================

void WebrtcPeerConnection::CreateAnswer(const JNode& constraints,
                                        webrtc_handle pc, webrtc_result_cb cb,
                                        void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !cb) return;
  scoped_refptr<RTCMediaConstraints> media_constraints =
      h->base ? h->base->ParseMediaConstraints(constraints)
              : RTCMediaConstraints::Create();

  h->pc->CreateAnswer(
      [cb, ud](const string sdp, const string type) {
        std::string json = ToJson(MakeObj({{"sdp", MakeStr(sdp.std_string())},
                                           {"type", MakeStr(type.std_string())}}));
        cb(ud, 0, json.c_str());
      },
      [cb, ud](const char* error) { cb(ud, -1, nullptr); }, media_constraints);
}

void WebrtcPeerConnection::SetLocalDescription(const char* sdp, const char* type,
                                               webrtc_handle pc,
                                               webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !cb) return;
  h->pc->SetLocalDescription(
      sdp ? sdp : "", type ? type : "",
      [cb, ud]() { cb(ud, 0, nullptr); },
      [cb, ud](const char* error) { cb(ud, -1, nullptr); });
}

void WebrtcPeerConnection::SetRemoteDescription(const char* sdp,
                                                const char* type,
                                                webrtc_handle pc,
                                                webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !cb) return;
  h->pc->SetRemoteDescription(
      sdp ? sdp : "", type ? type : "",
      [cb, ud]() { cb(ud, 0, nullptr); },
      [cb, ud](const char* error) { cb(ud, -1, nullptr); });
}

// ================= 被控: ICE =================

int WebrtcPeerConnection::AddIceCandidate(webrtc_handle pc,
                                          const char* candidate_json) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !candidate_json) return -1;

  JNode c = ParseJson(candidate_json);
  int sdp_mline_index = 0;
  const JNode* mline = c.Get("sdpMLineIndex");
  if (mline && mline->type == JNode::kNum) sdp_mline_index = static_cast<int>(mline->n);
  h->pc->AddCandidate(c.StrOf("sdpMid").c_str(), sdp_mline_index,
                      c.StrOf("candidate").c_str());
  return 0;
}

// ================= 被控: 发送媒体 =================

char* WebrtcPeerConnection::AddTrack(webrtc_handle pc, const char* track_id,
                                     const char* stream_id) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !track_id) return nullptr;

  scoped_refptr<RTCMediaTrack> track = h->base->MediaTrackForId(track_id);
  if (!track) return nullptr;

  std::vector<string> ids;
  if (stream_id) ids.push_back(stream_id);
  vector<string> stream_ids(ids);  // portable::vector, 从 std::vector 构造

  scoped_refptr<RTCRtpSender> sender = h->pc->AddTrack(track, stream_ids);
  if (!sender) return nullptr;
  return StrDup(ToJson(RtpSenderToJNode(sender.get())));
}

char* WebrtcPeerConnection::RemoveTrack(webrtc_handle pc,
                                        const char* sender_id) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !sender_id) return nullptr;
  scoped_refptr<RTCRtpSender> sender = FindSenderById(h, sender_id);
  if (!sender) return nullptr;
  bool ok = h->pc->RemoveTrack(sender);
  return StrDup(ToJson(MakeObj({{"result", MakeBool(ok)}})));
}

char* WebrtcPeerConnection::GetSenders(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return nullptr;
  JNode list;
  list.type = JNode::kArr;
  for (auto& sender : h->pc->senders().std_vector())
    list.arr.push_back(RtpSenderToJNode(sender.get()));
  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("senders", std::move(list));
  return StrDup(ToJson(result));
}

char* WebrtcPeerConnection::GetTransceivers(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return nullptr;
  JNode list;
  list.type = JNode::kArr;
  for (auto& transceiver : h->pc->transceivers().std_vector())
    list.arr.push_back(TransceiverToJNode(transceiver.get()));
  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("transceivers", std::move(list));
  return StrDup(ToJson(result));
}

char* WebrtcPeerConnection::RtpSenderSetParameters(webrtc_handle pc,
                                                   const char* sender_id,
                                                   const char* params_json) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !sender_id) return nullptr;
  scoped_refptr<RTCRtpSender> sender = FindSenderById(h, sender_id);
  if (!sender) return nullptr;

  scoped_refptr<RTCRtpParameters> params = sender->parameters();
  UpdateRtpParameters(ParseJson(params_json), params);
  bool ok = sender->set_parameters(params);
  return StrDup(ToJson(MakeObj({{"result", MakeBool(ok)}})));
}

void WebrtcPeerConnection::RtpTransceiverSetCodecPreferences(
    webrtc_handle pc, const char* transceiver_id, const char* codecs_json) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !transceiver_id) return;
  scoped_refptr<RTCRtpTransceiver> transceiver =
      FindTransceiverById(h, transceiver_id);
  if (!transceiver) return;

  JNode codecs = ParseJson(codecs_json);
  std::vector<scoped_refptr<RTCRtpCodecCapability>> codec_list;
  if (codecs.type == JNode::kArr) {
    for (auto& codec : codecs.arr) {
      if (codec.type != JNode::kObj) continue;
      scoped_refptr<RTCRtpCodecCapability> cap = RTCRtpCodecCapability::Create();
      if (!cap) continue;
      cap->set_mime_type(codec.StrOf("mimeType").c_str());
      const JNode* clock_rate = codec.Get("clockRate");
      if (clock_rate && clock_rate->type == JNode::kNum)
        cap->set_clock_rate(static_cast<int>(clock_rate->n));
      const JNode* channels = codec.Get("channels");
      if (channels && channels->type == JNode::kNum)
        cap->set_channels(static_cast<int>(channels->n));
      std::string fmtp = codec.StrOf("sdpFmtpLine");
      if (!fmtp.empty()) cap->set_sdp_fmtp_line(fmtp.c_str());
      codec_list.push_back(cap);
    }
  }
  vector<scoped_refptr<RTCRtpCodecCapability>> pcodes(codec_list);
  transceiver->SetCodecPreferences(pcodes);
}

void WebrtcPeerConnection::GetStats(webrtc_handle pc, const char* track_id,
                                    webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !cb) return;

  std::string tid = track_id ? track_id : "";
  scoped_refptr<RTCMediaTrack> track =
      tid.empty() ? nullptr : h->base->MediaTrackForId(tid);
  if (!track && !tid.empty()) track = h->observer.MediaTrackForId(tid);

  auto success = [cb, ud](const vector<scoped_refptr<MediaRTCStats>> reports) {
    JNode list;
    list.type = JNode::kArr;
    for (auto& r : reports.std_vector()) list.arr.push_back(StatsToJNode(r.get()));
    JNode result;
    result.type = JNode::kObj;
    result.obj.emplace_back("stats", std::move(list));
    std::string json = ToJson(result);
    cb(ud, 0, json.c_str());
  };
  auto failure = [cb, ud](const char* error) { cb(ud, -1, nullptr); };

  if (track) {
    // 参考 GetStats: 先 receiver 后 sender
    for (auto& receiver : h->pc->receivers().std_vector()) {
      if (receiver->track() && receiver->track()->id().c_string() == tid) {
        h->pc->GetStats(receiver, std::move(success), std::move(failure));
        return;
      }
    }
    for (auto& sender : h->pc->senders().std_vector()) {
      if (sender->track() && sender->track()->id().c_string() == tid) {
        h->pc->GetStats(sender, std::move(success), std::move(failure));
        return;
      }
    }
    cb(ud, -1, nullptr);
  } else {
    h->pc->GetStats(std::move(success), std::move(failure));
  }
}

// ================= 生命周期 =================

void WebrtcPeerConnection::Close(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return;
  h->pc->Close();
}

void WebrtcPeerConnection::Dispose(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h) return;
  if (h->pc) h->pc->DeRegisterRTCPeerConnectionObserver();
  delete h;
}

// ================= 主控/非被控录制, 无需实现 =================
// CreateOffer               — 主控发起 offer, 被控只 createAnswer
// GetLocalDescription       — 调试用, 不涉及被控录制
// GetRemoteDescription      — 调试用, 不涉及被控录制
// AddTransceiver            — 被控发送用 addTrack(内部走 AddTransceiver)
// GetReceivers              — 被控不接收远端媒体(主控端用)
// RtpSenderSetTrack/SetStream/ReplaceTrack — 被控 addTrack 已建 sender, 无需
// RtpTransceiverStop/GetCurrentDirection/SetDirection — 发送方向管理, 非录制必需
// SetConfiguration          — 参考 flutter 本身即 TODO
// CaptureFrame              — 需要单独的 frame_capturer 模块, 后续批次补

}  // namespace webrtc
