#ifndef WEBRTC_FRAME_CRYPTOR_HXX
#define WEBRTC_FRAME_CRYPTOR_HXX

/* 对应 flutter_frame_cryptor.h 的 FlutterFrameCryptor (+ FlutterFrameCryptorObserver):
 * E2EE 帧加密。RTCFrameCryptor + KeyProvider 的创建/配置/销毁和状态事件。
 *
 * 采用常驻对象模式: 挂在 WebrtcBase 上(同 screen_capture_),
 * 跨调用保存 frame_cryptors_ / key_providers_ 注册表, 按键 id 引用。
 * 状态事件 OnFrameCryptionStateChanged 经 factory_event_cb_ 推给 dart。 */
#include <map>
#include <string>

#include "rtc_frame_cryptor.h"

#include "webrtc_base.h"
#include "webrtc_common.h"

namespace webrtc {

using namespace libwebrtc;

// 观察者: 把 RTCFrameCryptor 状态事件转成 JSON 经 factory_event_cb_ 推送
class WebrtcFrameCryptorObserver : public RTCFrameCryptorObserver {
 public:
  void SetBase(WebrtcBase* base) { base_ = base; }
  void OnFrameCryptionStateChanged(const string participant_id,
                                   RTCFrameCryptionState state) override;

 private:
  WebrtcBase* base_ = nullptr;
};

class WebrtcFrameCryptor {
 public:
  explicit WebrtcFrameCryptor(WebrtcBase* base) : base_(base) {}

  // type: "sender"|"receiver", 创建 frameCryptor 绑定到指定 pc 上的 sender/receiver。
  // pc 直接用调用方持有的句柄(本 C ABI 以句柄而非 peerConnectionId 传递)。
  // 返回 {"frameCryptorId":uuid}, 失败空串
  std::string FrameCryptorFactoryCreateFrameCryptor(RTCPeerConnection* pc,
                                                    const JNode& constraints);

  // 对指定 frameCryptorId 的 get/set keyIndex / enabled / dispose
  // get 返回 {"keyIndex":n} / {"enabled":bool}; set 返回 {"result":...}; dispose 返回 {"result":"success"}
  std::string FrameCryptorSetKeyIndex(const JNode& constraints);
  std::string FrameCryptorGetKeyIndex(const JNode& constraints);
  std::string FrameCryptorSetEnabled(const JNode& constraints);
  std::string FrameCryptorGetEnabled(const JNode& constraints);
  std::string FrameCryptorDispose(const JNode& constraints);

  // KeyProvider: 创建(从 keyProviderOptions)→ {"keyProviderId":uuid}
  std::string FrameCryptorFactoryCreateKeyProvider(const JNode& constraints);

  // KeyProvider 各类 key 操作, 返回 {"result":...}(可能带字节数组)
  std::string KeyProviderSetSharedKey(const JNode& constraints);
  std::string KeyProviderRatchetSharedKey(const JNode& constraints);
  std::string KeyProviderExportSharedKey(const JNode& constraints);
  std::string KeyProviderSetKey(const JNode& constraints);
  std::string KeyProviderRatchetKey(const JNode& constraints);
  std::string KeyProviderExportKey(const JNode& constraints);
  std::string KeyProviderSetSifTrailer(const JNode& constraints);
  std::string KeyProviderDispose(const JNode& constraints);

  // DataPacketCryptor 复用同一批 KeyProvider(参考上游 base_->key_providers_)
  scoped_refptr<KeyProvider> GetKeyProviderForId(
      const std::string& key_provider_id);

 private:
  // JNode 字节数组(view) → std::vector<uint8_t>
  static std::vector<uint8_t> BytesOf(const JNode& v);

  WebrtcBase* base_;
  std::map<std::string, scoped_refptr<RTCFrameCryptor>> frame_cryptors_;
  std::map<std::string, scoped_refptr<WebrtcFrameCryptorObserver>>
      frame_cryptor_observers_;
  std::map<std::string, scoped_refptr<KeyProvider>> key_providers_;
};

}  // namespace webrtc

#endif  // WEBRTC_FRAME_CRYPTOR_HXX
