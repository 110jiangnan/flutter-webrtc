#include "webrtc_base.h"

#include "helper.h"

#include "webrtc_data_channel.h"  // 析构 data_channel_observers_ 需要完整类型
#include "webrtc_screen_capture.h"  // 析构 screen_capture_ 需要完整类型
#include "webrtc_frame_cryptor.h"  // 析构 frame_cryptor_ 需要完整类型

namespace webrtc {

using namespace libwebrtc;

WebrtcBase::WebrtcBase() {}

WebrtcBase::~WebrtcBase() {
  local_streams_.clear();
  local_tracks_.clear();
  video_capturers_.clear();
  desktop_capturers_.clear();
  desktop_stream_sources_.clear();
  data_channel_observers_.clear();
  screen_capture_.reset();
  frame_cryptor_.reset();
  peerconnections_.clear();
  peerconnection_observers_.clear();
}

bool WebrtcBase::Initialize() {
  if (!LibWebRTC::Initialize()) return false;

  factory_ = LibWebRTC::CreateRTCPeerConnectionFactory();
  if (!factory_) return false;
  factory_->Initialize();

  // 系统音频专用 factory: 不初始化默认音频设备模块, 避免与麦克风采集互抢
  empty_adm_factory_ = LibWebRTC::CreateRTCPeerConnectionFactory();
  if (empty_adm_factory_) {
    empty_adm_factory_->is_myaudio = true;
    empty_adm_factory_->Initialize();
  }

  audio_device_ = factory_->GetAudioDevice();
  video_device_ = factory_->GetVideoDevice();
  desktop_device_ = factory_->GetDesktopDevice();
  audio_processing_ = factory_->GetAudioProcessing();
  return true;
}

std::string WebrtcBase::GenerateUUID() {
  return Helper::CreateRandomUuid().std_string();
}

RTCPeerConnection* WebrtcBase::PeerConnectionForId(const std::string& id) {
  auto it = peerconnections_.find(id);
  return it != peerconnections_.end() ? it->second.get() : nullptr;
}

void WebrtcBase::RemovePeerConnectionForId(const std::string& id) {
  auto it = peerconnections_.find(id);
  if (it != peerconnections_.end()) peerconnections_.erase(it);
}

CppPcObserver* WebrtcBase::PeerConnectionObserversForId(
    const std::string& id) {
  auto it = peerconnection_observers_.find(id);
  return it != peerconnection_observers_.end() ? it->second : nullptr;
}

void WebrtcBase::RemovePeerConnectionObserversForId(const std::string& id) {
  auto it = peerconnection_observers_.find(id);
  if (it != peerconnection_observers_.end()) peerconnection_observers_.erase(it);
}

scoped_refptr<RTCMediaStream> WebrtcBase::MediaStreamForId(
    const std::string& id) {
  auto it = local_streams_.find(id);
  return it != local_streams_.end() ? it->second : nullptr;
}

scoped_refptr<RTCMediaTrack> WebrtcBase::MediaTrackForId(const std::string& id) {
  auto it = local_tracks_.find(id);
  return it != local_tracks_.end() ? it->second : nullptr;
}

void WebrtcBase::RemoveMediaTrackForId(const std::string& id) {
  local_tracks_.erase(id);
}

void WebrtcBase::ParseRTCConfiguration(const JNode& map,
                                       RTCConfiguration& conf) {
  // iceServers: 参考 CreateIceServers, urls 数组里每个 server 的 uri 取最后一个
  const JNode* ice_servers = map.Get("iceServers");
  if (ice_servers && ice_servers->type == JNode::kArr) {
    int count = 0;
    for (auto& server : ice_servers->arr) {
      if (count >= kMaxIceServerSize) break;
      if (server.type != JNode::kObj) continue;
      IceServer& ice_server = conf.ice_servers[count];
      ice_server.username = server.StrOf("username");
      ice_server.password = server.StrOf("credential");
      const JNode* urls = server.Get("urls");
      std::string url;
      if (urls && urls->type == JNode::kStr) {
        url = urls->s;
      } else if (urls && urls->type == JNode::kArr) {
        for (auto& u : urls->arr) {
          if (u.type == JNode::kObj) {
            std::string nested = u.StrOf("url");
            if (!nested.empty()) url = nested;
          } else if (u.type == JNode::kStr) {
            url = u.s;
          }
        }
      }
      if (!url.empty()) ice_server.uri = url;
      ++count;
    }
  }

  // iceTransportPolicy
  std::string v = map.StrOf("iceTransportPolicy");
  if (!v.empty()) {
    if (v == "all") conf.type = IceTransportsType::kAll;
    else if (v == "relay") conf.type = IceTransportsType::kRelay;
    else if (v == "nohost") conf.type = IceTransportsType::kNoHost;
    else if (v == "none") conf.type = IceTransportsType::kNone;
  }

  // bundlePolicy
  v = map.StrOf("bundlePolicy");
  if (v == "balanced") conf.bundle_policy = kBundlePolicyBalanced;
  else if (v == "max-compat") conf.bundle_policy = kBundlePolicyMaxCompat;
  else if (v == "max-bundle") conf.bundle_policy = kBundlePolicyMaxBundle;

  // rtcpMuxPolicy
  v = map.StrOf("rtcpMuxPolicy");
  if (v == "negotiate") conf.rtcp_mux_policy = RtcpMuxPolicy::kRtcpMuxPolicyNegotiate;
  else if (v == "require") conf.rtcp_mux_policy = RtcpMuxPolicy::kRtcpMuxPolicyRequire;

  // iceCandidatePoolSize
  const JNode* pool = map.Get("iceCandidatePoolSize");
  if (pool && pool->type == JNode::kNum)
    conf.ice_candidate_pool_size = static_cast<int>(pool->n);

  // sdpSemantics
  v = map.StrOf("sdpSemantics");
  if (v == "plan-b") conf.sdp_semantics = SdpSemantics::kPlanB;
  else conf.sdp_semantics = SdpSemantics::kUnifiedPlan;  // 参考: 默认 unified-plan

  // maxIPv6Networks
  const JNode* ipv6 = map.Get("maxIPv6Networks");
  if (ipv6 && ipv6->type == JNode::kNum)
    conf.max_ipv6_networks = static_cast<int>(ipv6->n);
}

scoped_refptr<RTCRtpSender> WebrtcBase::GetRtpSenderById(
    RTCPeerConnection* pc, const std::string& id) {
  for (auto& item : pc->senders().std_vector()) {
    if (item->id().std_string() == id) return item;
  }
  return nullptr;
}

scoped_refptr<RTCRtpReceiver> WebrtcBase::GetRtpReceiverById(
    RTCPeerConnection* pc, const std::string& id) {
  for (auto& item : pc->receivers().std_vector()) {
    if (item->id().std_string() == id) return item;
  }
  return nullptr;
}

scoped_refptr<RTCMediaConstraints> WebrtcBase::ParseMediaConstraints(
    const JNode& constraints) {
  scoped_refptr<RTCMediaConstraints> media_constraints =
      RTCMediaConstraints::Create();

  const JNode* mandatory = constraints.Get("mandatory");
  if (mandatory && mandatory->type == JNode::kObj)
    ParseConstraints(*mandatory, media_constraints, kMandatory);

  const JNode* optional = constraints.Get("optional");
  if (optional && optional->type == JNode::kObj) {
    ParseConstraints(*optional, media_constraints, kOptional);
  } else if (optional && optional->type == JNode::kArr) {
    for (auto& item : optional->arr) {
      if (item.type == JNode::kObj)
        ParseConstraints(item, media_constraints, kOptional);
    }
  }
  return media_constraints;
}

void WebrtcBase::ParseConstraints(
    const JNode& src, scoped_refptr<RTCMediaConstraints> media_constraints,
    ParseConstraintType type) {
  for (auto& kv : src.obj) {
    const std::string& key = kv.first;
    const JNode& v = kv.second;
    std::string value;
    if (v.type == JNode::kStr) {
      value = v.s;
    } else if (v.type == JNode::kNum) {
      value = std::to_string(v.n);  // 参考: double → to_string
    } else if (v.type == JNode::kBool) {
      value = v.b ? RTCMediaConstraints::kValueTrue
                  : RTCMediaConstraints::kValueFalse;
    } else {
      continue;  // 数组/对象跳过(参考)
    }
    if (type == kMandatory) {
      media_constraints->AddMandatoryConstraint(key.c_str(), value.c_str());
    } else {
      media_constraints->AddOptionalConstraint(key.c_str(), value.c_str());
      if (key == "DtlsSrtpKeyAgreement") {
        configuration_.srtp_type =
            (v.type == JNode::kBool && v.b) ? MediaSecurityType::kDTLS_SRTP
                                            : MediaSecurityType::kSDES_SRTP;
      }
    }
  }
}

void WebrtcBase::RemoveStreamForId(const std::string& stream_id) {
  auto it = local_streams_.find(stream_id);
  if (it == local_streams_.end()) return;

  // 顺带释放该流轨道对应的 capturer / track 注册
  auto tracks = it->second->tracks().std_vector();
  for (auto& track : tracks) {
    video_capturers_.erase(track->id().std_string());
    local_tracks_.erase(track->id().std_string());
  }
  local_streams_.erase(it);
}

}  // namespace webrtc
