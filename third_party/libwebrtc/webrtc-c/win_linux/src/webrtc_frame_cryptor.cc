#include "webrtc_frame_cryptor.h"

#include "base/refcountedobject.h"

namespace webrtc {

using namespace libwebrtc;

namespace {

// 参考 AlgorithmFromInt
Algorithm AlgorithmFromInt(int algorithm) {
  switch (algorithm) {
    case 0: return Algorithm::kAesGcm;
    case 1: return Algorithm::kAesCbc;
    default: return Algorithm::kAesGcm;
  }
}

// 参考 KeyDerivationAlgorithmFromInt: 0=kPBKDF2, 1=kHKDF
KeyDerivationAlgorithm KeyDerivationAlgorithmFromInt(int algorithm) {
  switch (algorithm) {
    case 0: return KeyDerivationAlgorithm::kPBKDF2;
    case 1: return KeyDerivationAlgorithm::kHKDF;
    default: return KeyDerivationAlgorithm::kPBKDF2;
  }
}

// 参考 frameCryptionStateToString
const char* FrameCryptionStateToString(RTCFrameCryptionState state) {
  switch (state) {
    case RTCFrameCryptionState::kNew: return "new";
    case RTCFrameCryptionState::kOk: return "ok";
    case RTCFrameCryptionState::kDecryptionFailed: return "decryptionFailed";
    case RTCFrameCryptionState::kEncryptionFailed: return "encryptionFailed";
    case RTCFrameCryptionState::kInternalError: return "internalError";
    case RTCFrameCryptionState::kKeyRatcheted: return "keyRatcheted";
    case RTCFrameCryptionState::kMissingKey: return "missingKey";
  }
  return "";
}

}  // namespace

void WebrtcFrameCryptorObserver::OnFrameCryptionStateChanged(
    const string participant_id, RTCFrameCryptionState state) {
  if (!base_ || !base_->factory_event_cb_) return;
  std::string json = ToJson(MakeObj({
      {"event", MakeStr("frameCryptionStateChanged")},
      {"participantId", MakeStr(participant_id.std_string())},
      {"state", MakeStr(FrameCryptionStateToString(state))},
  }));
  base_->factory_event_cb_(base_->factory_event_ud_, StrDup(json), nullptr, 0);
}

std::vector<uint8_t> WebrtcFrameCryptor::BytesOf(const JNode& v) {
  std::vector<uint8_t> out;
  if (v.type == JNode::kArr) {
    for (auto& item : v.arr)
      if (item.type == JNode::kNum) out.push_back(static_cast<uint8_t>(item.n));
  }
  return out;
}

std::string WebrtcFrameCryptor::FrameCryptorFactoryCreateFrameCryptor(
    RTCPeerConnection* pc, const JNode& constraints) {
  std::string type = constraints.StrOf("type");
  if (type.empty()) return "";
  if (!pc) return "";

  std::string rtp_sender_id = constraints.StrOf("rtpSenderId");
  std::string rtp_receiver_id = constraints.StrOf("rtpReceiverId");
  if (rtp_sender_id.empty() && rtp_receiver_id.empty()) return "";

  int algorithm = 0;
  const JNode* algo = constraints.Get("algorithm");
  if (algo && algo->type == JNode::kNum) algorithm = static_cast<int>(algo->n);
  std::string participant_id = constraints.StrOf("participantId");
  std::string key_provider_id = constraints.StrOf("keyProviderId");

  scoped_refptr<KeyProvider> key_provider = key_providers_[key_provider_id];
  if (!key_provider) return "";

  std::string uuid = base_->GenerateUUID();
  scoped_refptr<RTCFrameCryptor> frame_cryptor;
  if (type == "sender") {
    scoped_refptr<RTCRtpSender> sender = base_->GetRtpSenderById(pc, rtp_sender_id);
    if (!sender) return "";
    frame_cryptor = FrameCryptorFactory::frameCryptorFromRtpSender(
        base_->factory_, string(participant_id.c_str()), sender,
        AlgorithmFromInt(algorithm), key_provider);
  } else if (type == "receiver") {
    scoped_refptr<RTCRtpReceiver> receiver =
        base_->GetRtpReceiverById(pc, rtp_receiver_id);
    if (!receiver) return "";
    frame_cryptor = FrameCryptorFactory::frameCryptorFromRtpReceiver(
        base_->factory_, string(participant_id.c_str()), receiver,
        AlgorithmFromInt(algorithm), key_provider);
  } else {
    return "";
  }
  if (!frame_cryptor) return "";

  scoped_refptr<WebrtcFrameCryptorObserver> observer =
      new RefCountedObject<WebrtcFrameCryptorObserver>();
  observer->SetBase(base_);
  frame_cryptor->RegisterRTCFrameCryptorObserver(observer);
  frame_cryptors_[uuid] = frame_cryptor;
  frame_cryptor_observers_[uuid] = observer;

  return ToJson(MakeObj({{"frameCryptorId", MakeStr(uuid)}}));
}

std::string WebrtcFrameCryptor::FrameCryptorSetKeyIndex(
    const JNode& constraints) {
  std::string id = constraints.StrOf("frameCryptorId");
  auto it = frame_cryptors_.find(id);
  if (it == frame_cryptors_.end()) return "";
  int key_index = 0;
  const JNode* ki = constraints.Get("keyIndex");
  if (ki && ki->type == JNode::kNum) key_index = static_cast<int>(ki->n);
  bool res = it->second->SetKeyIndex(key_index);
  return ToJson(MakeObj({{"result", MakeBool(res)}}));
}

std::string WebrtcFrameCryptor::FrameCryptorGetKeyIndex(
    const JNode& constraints) {
  std::string id = constraints.StrOf("frameCryptorId");
  auto it = frame_cryptors_.find(id);
  if (it == frame_cryptors_.end()) return "";
  return ToJson(MakeObj({{"keyIndex", MakeNum(it->second->key_index())}}));
}

std::string WebrtcFrameCryptor::FrameCryptorSetEnabled(
    const JNode& constraints) {
  std::string id = constraints.StrOf("frameCryptorId");
  auto it = frame_cryptors_.find(id);
  if (it == frame_cryptors_.end()) return "";
  bool enabled = false;
  const JNode* e = constraints.Get("enabled");
  if (e && e->type == JNode::kBool) enabled = e->b;
  it->second->SetEnabled(enabled);
  return ToJson(MakeObj({{"result", MakeBool(enabled)}}));
}

std::string WebrtcFrameCryptor::FrameCryptorGetEnabled(
    const JNode& constraints) {
  std::string id = constraints.StrOf("frameCryptorId");
  auto it = frame_cryptors_.find(id);
  if (it == frame_cryptors_.end()) return "";
  return ToJson(MakeObj({{"enabled", MakeBool(it->second->enabled())}}));
}

std::string WebrtcFrameCryptor::FrameCryptorDispose(const JNode& constraints) {
  std::string id = constraints.StrOf("frameCryptorId");
  auto it = frame_cryptors_.find(id);
  if (it == frame_cryptors_.end()) return "";
  it->second->DeRegisterRTCFrameCryptorObserver();
  frame_cryptors_.erase(id);
  frame_cryptor_observers_.erase(id);
  return ToJson(MakeObj({{"result", MakeStr("success")}}));
}

std::string WebrtcFrameCryptor::FrameCryptorFactoryCreateKeyProvider(
    const JNode& constraints) {
  const JNode* options = constraints.Get("keyProviderOptions");
  if (!options || options->type != JNode::kObj) return "";

  KeyProviderOptions kpo;
  const JNode* shared_key = options->Get("sharedKey");
  if (shared_key && shared_key->type == JNode::kBool)
    kpo.shared_key = shared_key->b;
  const JNode* uncrypted = options->Get("uncryptedMagicBytes");
  if (uncrypted && uncrypted->type == JNode::kArr)
    kpo.uncrypted_magic_bytes = BytesOf(*uncrypted);
  const JNode* salt = options->Get("ratchetSalt");
  if (!salt || salt->type != JNode::kArr || salt->arr.empty()) return "";
  kpo.ratchet_salt = BytesOf(*salt);
  const JNode* window_size = options->Get("ratchetWindowSize");
  if (!window_size || window_size->type != JNode::kNum) return "";
  kpo.ratchet_window_size = static_cast<int>(window_size->n);
  const JNode* failure = options->Get("failureTolerance");
  if (failure && failure->type == JNode::kNum)
    kpo.failure_tolerance = static_cast<int>(failure->n);
  const JNode* ring = options->Get("keyRingSize");
  if (ring && ring->type == JNode::kNum)
    kpo.key_ring_size = static_cast<int>(ring->n);
  const JNode* discard = options->Get("discardFrameWhenCryptorNotReady");
  if (discard && discard->type == JNode::kBool)
    kpo.discard_frame_when_cryptor_not_ready = discard->b;
  const JNode* kdf = options->Get("keyDerivationAlgorithm");
  if (kdf && kdf->type == JNode::kNum)
    kpo.key_derivation_algorithm =
        KeyDerivationAlgorithmFromInt(static_cast<int>(kdf->n));

  scoped_refptr<KeyProvider> key_provider = KeyProvider::Create(&kpo);
  if (!key_provider) return "";
  std::string uuid = base_->GenerateUUID();
  key_providers_[uuid] = key_provider;
  return ToJson(MakeObj({{"keyProviderId", MakeStr(uuid)}}));
}

std::string WebrtcFrameCryptor::KeyProviderSetSharedKey(
    const JNode& constraints) {
  auto it = key_providers_.find(constraints.StrOf("keyProviderId"));
  if (it == key_providers_.end()) return "";
  const JNode* key = constraints.Get("key");
  if (!key || key->type != JNode::kArr) return "";
  const JNode* idx = constraints.Get("keyIndex");
  if (!idx || idx->type != JNode::kNum) return "";
  bool res = it->second->SetSharedKey(static_cast<int>(idx->n), BytesOf(*key));
  return ToJson(MakeObj({{"result", MakeBool(res)}}));
}

std::string WebrtcFrameCryptor::KeyProviderRatchetSharedKey(
    const JNode& constraints) {
  auto it = key_providers_.find(constraints.StrOf("keyProviderId"));
  if (it == key_providers_.end()) return "";
  const JNode* idx = constraints.Get("keyIndex");
  if (!idx || idx->type != JNode::kNum) return "";
  vector<uint8_t> material = it->second->RatchetSharedKey(static_cast<int>(idx->n));
  JNode arr;
  arr.type = JNode::kArr;
  for (uint8_t b : material.std_vector()) arr.arr.push_back(MakeNum(b));
  return ToJson(MakeObj({{"result", std::move(arr)}}));
}

std::string WebrtcFrameCryptor::KeyProviderExportSharedKey(
    const JNode& constraints) {
  auto it = key_providers_.find(constraints.StrOf("keyProviderId"));
  if (it == key_providers_.end()) return "";
  const JNode* idx = constraints.Get("keyIndex");
  if (!idx || idx->type != JNode::kNum) return "";
  vector<uint8_t> material = it->second->ExportSharedKey(static_cast<int>(idx->n));
  JNode arr;
  arr.type = JNode::kArr;
  for (uint8_t b : material.std_vector()) arr.arr.push_back(MakeNum(b));
  return ToJson(MakeObj({{"result", std::move(arr)}}));
}

std::string WebrtcFrameCryptor::KeyProviderSetKey(const JNode& constraints) {
  auto it = key_providers_.find(constraints.StrOf("keyProviderId"));
  if (it == key_providers_.end()) return "";
  const JNode* key = constraints.Get("key");
  if (!key || key->type != JNode::kArr) return "";
  const JNode* idx = constraints.Get("keyIndex");
  if (!idx || idx->type != JNode::kNum) return "";
  std::string participant = constraints.StrOf("participantId");
  if (participant.empty()) return "";
  bool res = it->second->SetKey(string(participant.c_str()),
                                static_cast<int>(idx->n), BytesOf(*key));
  return ToJson(MakeObj({{"result", MakeBool(res)}}));
}

std::string WebrtcFrameCryptor::KeyProviderRatchetKey(
    const JNode& constraints) {
  auto it = key_providers_.find(constraints.StrOf("keyProviderId"));
  if (it == key_providers_.end()) return "";
  const JNode* idx = constraints.Get("keyIndex");
  if (!idx || idx->type != JNode::kNum) return "";
  std::string participant = constraints.StrOf("participantId");
  if (participant.empty()) return "";
  vector<uint8_t> material =
      it->second->RatchetKey(string(participant.c_str()), static_cast<int>(idx->n));
  JNode arr;
  arr.type = JNode::kArr;
  for (uint8_t b : material.std_vector()) arr.arr.push_back(MakeNum(b));
  return ToJson(MakeObj({{"result", std::move(arr)}}));
}

std::string WebrtcFrameCryptor::KeyProviderExportKey(const JNode& constraints) {
  auto it = key_providers_.find(constraints.StrOf("keyProviderId"));
  if (it == key_providers_.end()) return "";
  const JNode* idx = constraints.Get("keyIndex");
  if (!idx || idx->type != JNode::kNum) return "";
  std::string participant = constraints.StrOf("participantId");
  if (participant.empty()) return "";
  vector<uint8_t> material =
      it->second->ExportKey(string(participant.c_str()), static_cast<int>(idx->n));
  JNode arr;
  arr.type = JNode::kArr;
  for (uint8_t b : material.std_vector()) arr.arr.push_back(MakeNum(b));
  return ToJson(MakeObj({{"result", std::move(arr)}}));
}

std::string WebrtcFrameCryptor::KeyProviderSetSifTrailer(
    const JNode& constraints) {
  auto it = key_providers_.find(constraints.StrOf("keyProviderId"));
  if (it == key_providers_.end()) return "";
  const JNode* trailer = constraints.Get("sifTrailer");
  if (!trailer || trailer->type != JNode::kArr) return "";
  it->second->SetSifTrailer(BytesOf(*trailer));
  return ToJson(MakeObj({{"result", MakeBool(true)}}));
}

std::string WebrtcFrameCryptor::KeyProviderDispose(const JNode& constraints) {
  std::string id = constraints.StrOf("keyProviderId");
  auto it = key_providers_.find(id);
  if (it == key_providers_.end()) return "";
  key_providers_.erase(it);
  return ToJson(MakeObj({{"result", MakeStr("success")}}));
}

scoped_refptr<KeyProvider> WebrtcFrameCryptor::GetKeyProviderForId(
    const std::string& key_provider_id) {
  auto it = key_providers_.find(key_provider_id);
  return it == key_providers_.end() ? nullptr : it->second;
}

}  // namespace webrtc
