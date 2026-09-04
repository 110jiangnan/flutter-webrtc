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
        {"priority", MakeStr(BitratePriorityToString(enc->bitrate_priority()))},
        {"networkPriority", MakeStr(RTCPriorityToString(enc->network_priority()))},
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

// ---- 编码优先级(参考上游 749b356: priority↔bitratePriority, networkPriority↔RTCPriority) ----
static double StringToBitratePriority(const std::string& priority) {
  if (priority == "very-low") return 0.5;
  if (priority == "low") return 1.0;
  if (priority == "medium") return 2.0;
  if (priority == "high") return 4.0;
  return 1.0;
}

static std::string BitratePriorityToString(double bitrate_priority) {
  if (bitrate_priority <= 0.5) return "very-low";
  if (bitrate_priority <= 1.0) return "low";
  if (bitrate_priority <= 2.0) return "medium";
  return "high";
}

static RTCPriority StringToRTCPriority(const std::string& priority) {
  if (priority == "very-low") return RTCPriority::kVeryLow;
  if (priority == "low") return RTCPriority::kLow;
  if (priority == "medium") return RTCPriority::kMedium;
  if (priority == "high") return RTCPriority::kHigh;
  return RTCPriority::kLow;
}

static std::string RTCPriorityToString(RTCPriority priority) {
  switch (priority) {
    case RTCPriority::kVeryLow:
      return "very-low";
    case RTCPriority::kLow:
      return "low";
    case RTCPriority::kMedium:
      return "medium";
    case RTCPriority::kHigh:
      return "high";
  }
  return "low";
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
      const JNode* priority = map.Get("priority");
      if (priority && priority->type == JNode::kStr)
        param->set_bitrate_priority(StringToBitratePriority(priority->s));
      const JNode* network_priority = map.Get("networkPriority");
      if (network_priority && network_priority->type == JNode::kStr)
        param->set_network_priority(StringToRTCPriority(network_priority->s));
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

// ================= 主控/发送方辅助(对齐 flutter mapToRtpTransceiverInit 等) =================

RTCRtpTransceiverDirection TransceiverDirectionFromString(const std::string& d) {
  if (d == "sendrecv") return RTCRtpTransceiverDirection::kSendRecv;
  if (d == "sendonly") return RTCRtpTransceiverDirection::kSendOnly;
  if (d == "recvonly") return RTCRtpTransceiverDirection::kRecvOnly;
  if (d == "stoped") return RTCRtpTransceiverDirection::kStopped;
  if (d == "inactive") return RTCRtpTransceiverDirection::kInactive;
  return RTCRtpTransceiverDirection::kInactive;
}

RTCMediaType MediaTypeFromString(const std::string& s) {
  if (s == "audio") return RTCMediaType::AUDIO;
  if (s == "video") return RTCMediaType::VIDEO;
  if (s == "data") return RTCMediaType::DATA;
  return RTCMediaType::UNSUPPORTED;
}

// 参考 mapToEncoding: 默认 active=true, scaleResolutionDownBy=1.0
scoped_refptr<RTCRtpEncodingParameters> MapToEncoding(const JNode& map) {
  scoped_refptr<RTCRtpEncodingParameters> encoding =
      RTCRtpEncodingParameters::Create();
  encoding->set_active(true);
  encoding->set_scale_resolution_down_by(1.0);

  const JNode* active = map.Get("active");
  if (active && active->type == JNode::kBool) encoding->set_active(active->b);
  const JNode* rid = map.Get("rid");
  if (rid && rid->type == JNode::kStr) encoding->set_rid(rid->s.c_str());
  const JNode* ssrc = map.Get("ssrc");
  if (ssrc && ssrc->type == JNode::kNum)
    encoding->set_ssrc(static_cast<uint32_t>(ssrc->n));
  const JNode* min_bitrate = map.Get("minBitrate");
  if (min_bitrate && min_bitrate->type == JNode::kNum)
    encoding->set_min_bitrate_bps(static_cast<int>(min_bitrate->n));
  const JNode* max_bitrate = map.Get("maxBitrate");
  if (max_bitrate && max_bitrate->type == JNode::kNum)
    encoding->set_max_bitrate_bps(static_cast<int>(max_bitrate->n));
  const JNode* max_framerate = map.Get("maxFramerate");
  if (max_framerate && max_framerate->type == JNode::kNum)
    encoding->set_max_framerate(static_cast<int>(max_framerate->n));
  const JNode* priority = map.Get("priority");
  if (priority && priority->type == JNode::kStr)
    encoding->set_bitrate_priority(StringToBitratePriority(priority->s));
  const JNode* network_priority = map.Get("networkPriority");
  if (network_priority && network_priority->type == JNode::kStr)
    encoding->set_network_priority(StringToRTCPriority(network_priority->s));
  const JNode* num_temporal = map.Get("numTemporalLayers");
  if (num_temporal && num_temporal->type == JNode::kNum)
    encoding->set_num_temporal_layers(static_cast<int>(num_temporal->n));
  const JNode* scale = map.Get("scaleResolutionDownBy");
  if (scale && scale->type == JNode::kNum)
    encoding->set_scale_resolution_down_by(scale->n);
  const JNode* scalability = map.Get("scalabilityMode");
  if (scalability && scalability->type == JNode::kStr)
    encoding->set_scalability_mode(scalability->s.c_str());
  return encoding;
}

// 参考 mapToRtpTransceiverInit: 解析 direction/streamIds/sendEncodings
scoped_refptr<RTCRtpTransceiverInit> MapToRtpTransceiverInit(const JNode& init) {
  std::vector<string> stream_ids;
  const JNode* stream_ids_node = init.Get("streamIds");
  if (stream_ids_node && stream_ids_node->type == JNode::kArr) {
    for (auto& item : stream_ids_node->arr)
      if (item.type == JNode::kStr) stream_ids.push_back(item.s.c_str());
  }
  RTCRtpTransceiverDirection dir = RTCRtpTransceiverDirection::kInactive;
  const JNode* direction = init.Get("direction");
  if (direction && direction->type == JNode::kStr)
    dir = TransceiverDirectionFromString(direction->s);
  std::vector<scoped_refptr<RTCRtpEncodingParameters>> encodings;
  const JNode* send_encodings = init.Get("sendEncodings");
  if (send_encodings && send_encodings->type == JNode::kArr) {
    for (auto& item : send_encodings->arr)
      if (item.type == JNode::kObj) encodings.push_back(MapToEncoding(item));
  }
  return RTCRtpTransceiverInit::Create(dir, stream_ids, encodings);
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
  // 回调可能被 webrtc 线程异步触发(NativeCallable.listener 跨线程会编组到 Dart isolate,
  // 栈上 std::string 在回调真正执行时已析构), 必须传堆拷贝, Dart 侧用 webrtc_free_string 释放
  cb_(ud_, StrDup(json), nullptr, 0);
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

// ============================================================================
// WebrtcPeerConnection: 成员函数实现顺序对齐 flutter_peerconnection.h 的
// FlutterPeerConnection(Create↔CreateRTCPeerConnection, Close/Dispose↔
// RTCPeerConnectionClose/RTCPeerConnectionDispose)。
// ============================================================================

WebrtcPeerConnection::WebrtcPeerConnection(WebrtcBase* base) : base_(base) {}

// ---- 建连(CreateRTCPeerConnection) ----
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

// ---- RTCPeerConnectionClose ----
void WebrtcPeerConnection::Close(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return;
  h->pc->Close();
}

// ---- RTCPeerConnectionDispose ----
void WebrtcPeerConnection::Dispose(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h) return;
  if (h->pc) h->pc->DeRegisterRTCPeerConnectionObserver();
  delete h;
}

// ---- CreateOffer ----
void WebrtcPeerConnection::CreateOffer(const JNode& constraints,
                                       webrtc_handle pc, webrtc_result_cb cb,
                                       void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !cb) return;
  scoped_refptr<RTCMediaConstraints> media_constraints =
      h->base ? h->base->ParseMediaConstraints(constraints)
              : RTCMediaConstraints::Create();

  h->pc->CreateOffer(
      [cb, ud](const string sdp, const string type) {
        std::string json = ToJson(MakeObj({{"sdp", MakeStr(sdp.std_string())},
                                           {"type", MakeStr(type.std_string())}}));
        cb(ud, 0, StrDup(json));
      },
      [cb, ud](const char* error) { cb(ud, -1, nullptr); }, media_constraints);
}

// ---- CreateAnswer ----
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
        cb(ud, 0, StrDup(json));
      },
      [cb, ud](const char* error) { cb(ud, -1, nullptr); }, media_constraints);
}

// ---- SetLocalDescription / SetRemoteDescription ----
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

// ---- GetLocalDescription / GetRemoteDescription ----
void WebrtcPeerConnection::GetLocalDescription(webrtc_handle pc,
                                               webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !cb) return;
  h->pc->GetLocalDescription(
      [cb, ud](const char* sdp, const char* type) {
        std::string json = ToJson(MakeObj({{"sdp", MakeStr(sdp ? sdp : "")},
                                           {"type", MakeStr(type ? type : "")}}));
        cb(ud, 0, StrDup(json));
      },
      [cb, ud](const char* error) { cb(ud, -1, nullptr); });
}

void WebrtcPeerConnection::GetRemoteDescription(webrtc_handle pc,
                                                webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !cb) return;
  h->pc->GetRemoteDescription(
      [cb, ud](const char* sdp, const char* type) {
        std::string json = ToJson(MakeObj({{"sdp", MakeStr(sdp ? sdp : "")},
                                           {"type", MakeStr(type ? type : "")}}));
        cb(ud, 0, StrDup(json));
      },
      [cb, ud](const char* error) { cb(ud, -1, nullptr); });
}

// ---- AddTransceiver ----
// 参考的 mapToRtpTransceiverInit / stringToTransceiverDirection / mapToEncoding
// 辅助已做成匿名函数(见文件头匿名 namespace), 此处对接号即可。
char* WebrtcPeerConnection::AddTransceiver(webrtc_handle pc,
                                           const char* track_id,
                                           const char* media_type,
                                           const char* init_json) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return nullptr;

  scoped_refptr<RTCMediaTrack> track =
      track_id ? h->base->MediaTrackForId(track_id) : nullptr;
  JNode init = init_json ? ParseJson(init_json) : JNode();
  bool has_init = init.type == JNode::kObj && !init.obj.empty();

  scoped_refptr<RTCRtpTransceiver> transceiver;
  if (has_init) {
    scoped_refptr<RTCRtpTransceiverInit> tr_init = MapToRtpTransceiverInit(init);
    transceiver = track ? h->pc->AddTransceiver(track, tr_init)
                        : h->pc->AddTransceiver(MediaTypeFromString(media_type ? media_type : ""),
                                                tr_init);
  } else {
    transceiver = track ? h->pc->AddTransceiver(track)
                        : h->pc->AddTransceiver(MediaTypeFromString(media_type ? media_type : ""));
  }
  if (!transceiver) return nullptr;
  return StrDup(ToJson(TransceiverToJNode(transceiver.get())));
}

// ---- GetTransceivers ----
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

// ---- GetReceivers ----
char* WebrtcPeerConnection::GetReceivers(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return nullptr;
  JNode list;
  list.type = JNode::kArr;
  for (auto& receiver : h->pc->receivers().std_vector())
    list.arr.push_back(RtpReceiverToJNode(receiver.get()));
  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("receivers", std::move(list));
  return StrDup(ToJson(result));
}

// ---- RtpSenderSetTrack(含 RtpSenderReplaceTrack: 参考二者都走 set_track) ----
void WebrtcPeerConnection::RtpSenderSetTrack(webrtc_handle pc,
                                             const char* sender_id,
                                             const char* track_id,
                                             webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !sender_id || !cb) return;
  scoped_refptr<RTCRtpSender> sender = FindSenderById(h, sender_id);
  if (!sender) { cb(ud, -1, nullptr); return; }
  scoped_refptr<RTCMediaTrack> track =
      (track_id && *track_id) ? h->base->MediaTrackForId(track_id) : nullptr;
  bool ok = sender->set_track(track);
  cb(ud, ok ? 0 : -1, nullptr);
}

// ---- RtpSenderSetStream ----
void WebrtcPeerConnection::RtpSenderSetStream(webrtc_handle pc,
                                              const char* sender_id,
                                              const char* stream_ids_json,
                                              webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !sender_id || !cb) return;
  scoped_refptr<RTCRtpSender> sender = FindSenderById(h, sender_id);
  if (!sender) { cb(ud, -1, nullptr); return; }

  std::vector<string> ids;
  JNode node = stream_ids_json ? ParseJson(stream_ids_json) : JNode();
  if (node.type == JNode::kArr) {
    for (auto& item : node.arr)
      if (item.type == JNode::kStr) ids.push_back(item.s.c_str());
  }
  vector<string> stream_ids(ids);
  sender->set_stream_ids(stream_ids);
  cb(ud, 0, nullptr);
}

// ---- RtpSenderSetParameters ----
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

// ---- RtpTransceiverStop ----
void WebrtcPeerConnection::RtpTransceiverStop(webrtc_handle pc,
                                              const char* transceiver_id,
                                              webrtc_result_cb cb, void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !transceiver_id || !cb) return;
  scoped_refptr<RTCRtpTransceiver> transceiver =
      FindTransceiverById(h, transceiver_id);
  if (!transceiver) { cb(ud, -1, nullptr); return; }
  transceiver->StopInternal();
  cb(ud, 0, nullptr);
}

// ---- RtpTransceiverGetCurrentDirection ----
void WebrtcPeerConnection::RtpTransceiverGetCurrentDirection(
    webrtc_handle pc, const char* transceiver_id, webrtc_result_cb cb,
    void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !transceiver_id || !cb) return;
  scoped_refptr<RTCRtpTransceiver> transceiver =
      FindTransceiverById(h, transceiver_id);
  if (!transceiver) { cb(ud, -1, nullptr); return; }
  std::string json = ToJson(MakeObj({
      {"result", MakeStr(TransceiverDirectionString(transceiver->current_direction()))},
  }));
  cb(ud, 0, StrDup(json));
}

// ---- SetConfiguration(参考实现本身即 TODO, 这里仅成功返回) ----
void WebrtcPeerConnection::SetConfiguration(webrtc_handle pc,
                                            const char* configuration_json,
                                            webrtc_result_cb cb, void* ud) {
  if (cb) cb(ud, 0, nullptr);
}

// ---- RtpTransceiverSetDirection ----
void WebrtcPeerConnection::RtpTransceiverSetDirection(webrtc_handle pc,
                                                      const char* transceiver_id,
                                                      const char* direction,
                                                      webrtc_result_cb cb,
                                                      void* ud) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !transceiver_id || !direction || !cb) return;
  scoped_refptr<RTCRtpTransceiver> transceiver =
      FindTransceiverById(h, transceiver_id);
  if (!transceiver) { cb(ud, -1, nullptr); return; }
  auto res = transceiver->SetDirectionWithError(
      TransceiverDirectionFromString(direction));
  cb(ud, res.std_string().empty() ? 0 : -1, nullptr);
}

// ---- RtpTransceiverSetCodecPreferences ----
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

// ---- GetSenders ----
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

// ---- AddIceCandidate ----
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

// ---- GetStats ----
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
    cb(ud, 0, StrDup(json));
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

// ---- AddTrack / RemoveTrack ----
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

// ================= 补充: addStream/removeStream/restartIce/DTMF/状态查询 =================

int WebrtcPeerConnection::AddStream(webrtc_handle pc, const char* stream_id) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !stream_id || !h->base) return -1;
  scoped_refptr<RTCMediaStream> stream = h->base->MediaStreamForId(stream_id);
  if (!stream) return -1;
  return h->pc->AddStream(stream) ? 0 : -1;
}

int WebrtcPeerConnection::RemoveStream(webrtc_handle pc, const char* stream_id) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !stream_id || !h->base) return -1;
  scoped_refptr<RTCMediaStream> stream = h->base->MediaStreamForId(stream_id);
  if (!stream) return -1;
  return h->pc->RemoveStream(stream) ? 0 : -1;
}

void WebrtcPeerConnection::RestartIce(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return;
  h->pc->RestartIce();
}

int WebrtcPeerConnection::RtpSenderCanInsertDtmf(webrtc_handle pc,
                                                 const char* sender_id) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !sender_id) return 0;
  scoped_refptr<RTCRtpSender> sender = FindSenderById(h, sender_id);
  if (!sender || !sender->dtmf_sender()) return 0;
  return sender->dtmf_sender()->CanInsertDtmf() ? 1 : 0;
}

int WebrtcPeerConnection::RtpSenderInsertDtmf(webrtc_handle pc,
                                              const char* sender_id,
                                              const char* tones, int duration,
                                              int gap) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc || !sender_id || !tones) return 0;
  scoped_refptr<RTCRtpSender> sender = FindSenderById(h, sender_id);
  if (!sender || !sender->dtmf_sender()) return 0;
  return sender->dtmf_sender()->InsertDtmf(tones, duration, gap) ? 1 : 0;
}

char* WebrtcPeerConnection::GetSignalingState(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return StrDup("");
  return StrDup(ToJson(MakeObj({
      {"state", MakeStr(SignalingStateString(h->pc->signaling_state()))},
  })));
}

char* WebrtcPeerConnection::GetIceGatheringState(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return StrDup("");
  return StrDup(ToJson(MakeObj({
      {"state", MakeStr(IceGatheringStateString(h->pc->ice_gathering_state()))},
  })));
}

char* WebrtcPeerConnection::GetIceConnectionState(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return StrDup("");
  return StrDup(ToJson(MakeObj({
      {"state", MakeStr(IceConnectionStateString(h->pc->ice_connection_state()))},
  })));
}

char* WebrtcPeerConnection::GetConnectionState(webrtc_handle pc) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->pc) return StrDup("");
  return StrDup(ToJson(MakeObj({
      {"state", MakeStr(PeerConnectionStateString(h->pc->peer_connection_state()))},
  })));
}

// ================= 未实现 =================
// CaptureFrame — 需要单独的 frame_capturer 模块(渲染), 按需求排除。

}  // namespace webrtc
