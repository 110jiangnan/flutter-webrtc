// webrtc_data_packet_cryptor.cc — data channel 包 E2EE(参考 flutter_data_packet_cryptor.cc)。

#include "webrtc_data_packet_cryptor.h"

#include "webrtc_frame_cryptor.h"

namespace webrtc {

using namespace libwebrtc;

std::vector<uint8_t> WebrtcDataPacketCryptor::BytesOf(const JNode& v) {
  std::vector<uint8_t> out;
  if (v.type == JNode::kArr) {
    for (auto& item : v.arr)
      if (item.type == JNode::kNum) out.push_back(static_cast<uint8_t>(item.n));
  }
  return out;
}

std::string WebrtcDataPacketCryptor::CreateDataPacketCryptor(
    const JNode& constraints) {
  std::string key_provider_id = constraints.StrOf("keyProviderId");
  if (key_provider_id.empty()) return "";

  const JNode* algorithm = constraints.Get("algorithm");
  if (!algorithm || algorithm->type != JNode::kNum) return "";
  int alg = static_cast<int>(algorithm->n);

  // 复用 frame_cryptor 的 KeyProvider(参考上游 base_->key_providers_)
  if (!base_->frame_cryptor_) return "";
  scoped_refptr<KeyProvider> key_provider =
      base_->frame_cryptor_->GetKeyProviderForId(key_provider_id);
  if (!key_provider) return "";

  scoped_refptr<RTCDataPacketCryptor> data_cryptor =
      RTCDataPacketCryptor::Create(
          key_provider, static_cast<Algorithm>(alg));
  if (!data_cryptor) return "";

  std::string uuid = base_->GenerateUUID();
  data_packet_cryptors_[uuid] = data_cryptor;
  return ToJson(MakeObj({{"dataCryptorId", MakeStr(uuid)}}));
}

std::string WebrtcDataPacketCryptor::DataPacketCryptorDispose(
    const JNode& constraints) {
  std::string id = constraints.StrOf("dataCryptorId");
  auto it = data_packet_cryptors_.find(id);
  if (it == data_packet_cryptors_.end()) return "";
  data_packet_cryptors_.erase(it);
  return ToJson(MakeObj({{"result", MakeStr("success")}}));
}

std::string WebrtcDataPacketCryptor::DataPacketCryptorEncrypt(
    const JNode& constraints) {
  std::string id = constraints.StrOf("dataCryptorId");
  auto it = data_packet_cryptors_.find(id);
  if (it == data_packet_cryptors_.end()) return "";

  std::string participant_id = constraints.StrOf("participantId");
  if (participant_id.empty()) return "";

  const JNode* key_index = constraints.Get("keyIndex");
  if (!key_index || key_index->type != JNode::kNum) return "";

  const JNode* data = constraints.Get("data");
  if (!data || data->type != JNode::kArr || data->arr.empty()) return "";

  scoped_refptr<EncryptedPacket> encrypted_packet = it->second->encrypt(
      string(participant_id.c_str()), static_cast<int>(key_index->n),
      BytesOf(*data));
  if (!encrypted_packet) return "";

  JNode out_data;
  out_data.type = JNode::kArr;
  for (uint8_t b : encrypted_packet->data().std_vector())
    out_data.arr.push_back(MakeNum(b));
  JNode out_iv;
  out_iv.type = JNode::kArr;
  for (uint8_t b : encrypted_packet->iv().std_vector())
    out_iv.arr.push_back(MakeNum(b));

  return ToJson(MakeObj({{"data", std::move(out_data)},
                         {"iv", std::move(out_iv)},
                         {"keyIndex", MakeNum(encrypted_packet->key_index())}}));
}

std::string WebrtcDataPacketCryptor::DataPacketCryptorDecrypt(
    const JNode& constraints) {
  std::string id = constraints.StrOf("dataCryptorId");
  auto it = data_packet_cryptors_.find(id);
  if (it == data_packet_cryptors_.end()) return "";

  std::string participant_id = constraints.StrOf("participantId");
  if (participant_id.empty()) return "";

  const JNode* key_index = constraints.Get("keyIndex");
  if (!key_index || key_index->type != JNode::kNum) return "";

  const JNode* data = constraints.Get("data");
  if (!data || data->type != JNode::kArr || data->arr.empty()) return "";

  const JNode* iv = constraints.Get("iv");
  if (!iv || iv->type != JNode::kArr || iv->arr.empty()) return "";

  scoped_refptr<EncryptedPacket> packet = EncryptedPacket::Create(
      BytesOf(*data), BytesOf(*iv), static_cast<uint8_t>(key_index->n));
  vector<uint8_t> decrypted = it->second->decrypt(
      string(participant_id.c_str()), static_cast<int>(key_index->n), packet);
  if (decrypted.size() == 0) return "";

  JNode out_data;
  out_data.type = JNode::kArr;
  for (uint8_t b : decrypted.std_vector()) out_data.arr.push_back(MakeNum(b));

  return ToJson(MakeObj({{"data", std::move(out_data)}}));
}

}  // namespace webrtc
