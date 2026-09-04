#ifndef WEBRTC_DATA_PACKET_CRYPTOR_HXX
#define WEBRTC_DATA_PACKET_CRYPTOR_HXX

/* 对应 flutter_data_packet_cryptor.h 的 FlutterDataPacketCryptor:
 * data channel 包的 E2EE 加密/解密(与 FrameCryptor 加密媒体轨是两套)。
 *
 * 采用常驻对象模式: 挂在 WebrtcBase 上(同 frame_cryptor_),
 * 跨调用保存 data_packet_cryptors_ 注册表, 按键 id(dataCryptorId)引用。
 * 复用 frame_cryptor 的 KeyProvider(经 WebrtcFrameCryptor::GetKeyProviderForId)。 */
#include <map>
#include <string>

#include "rtc_data_packet_cryptor.h"

#include "webrtc_base.h"
#include "webrtc_common.h"

namespace webrtc {

using namespace libwebrtc;

class WebrtcDataPacketCryptor {
 public:
  explicit WebrtcDataPacketCryptor(WebrtcBase* base) : base_(base) {}

  // constraints: {"keyProviderId":uuid,"algorithm":0|1}
  // → {"dataCryptorId":uuid}, 失败空串
  std::string CreateDataPacketCryptor(const JNode& constraints);

  // constraints: {"dataCryptorId":uuid} → {"result":"success"}, 失败空串
  std::string DataPacketCryptorDispose(const JNode& constraints);

  // constraints: {"dataCryptorId":uuid,"participantId":str,"keyIndex":n,
  //               "data":[...]}
  // → {"data":[...],"iv":[...],"keyIndex":n}, 失败空串
  std::string DataPacketCryptorEncrypt(const JNode& constraints);

  // constraints: {"dataCryptorId":uuid,"participantId":str,"keyIndex":n,
  //               "data":[...],"iv":[...]}
  // → {"data":[...]}, 失败空串
  std::string DataPacketCryptorDecrypt(const JNode& constraints);

 private:
  // JNode 字节数组(view) → std::vector<uint8_t>
  static std::vector<uint8_t> BytesOf(const JNode& v);

  WebrtcBase* base_;
  std::map<std::string, scoped_refptr<RTCDataPacketCryptor>>
      data_packet_cryptors_;
};

}  // namespace webrtc

#endif  // WEBRTC_DATA_PACKET_CRYPTOR_HXX
