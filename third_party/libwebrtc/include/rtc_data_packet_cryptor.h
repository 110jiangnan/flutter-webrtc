#ifndef LIB_RTC_DATA_PACKET_CRYPTOR_H_
#define LIB_RTC_DATA_PACKET_CRYPTOR_H_

#include "base/refcount.h"
#include "rtc_frame_cryptor.h"
#include "rtc_types.h"

namespace libwebrtc {

/// Encrypted/decrypted data packet.
class EncryptedPacket : public RefCountInterface {
 public:
  LIB_WEBRTC_API static scoped_refptr<EncryptedPacket> Create(
      vector<uint8_t> data, vector<uint8_t> iv, uint8_t key_index);

  virtual vector<uint8_t> data() = 0;

  virtual vector<uint8_t> iv() = 0;

  virtual uint8_t key_index() = 0;

 protected:
  virtual ~EncryptedPacket() {}
};

/// Encrypts/decrypts data channel packets with the given KeyProvider.
class RTCDataPacketCryptor : public RefCountInterface {
 public:
  LIB_WEBRTC_API static scoped_refptr<RTCDataPacketCryptor> Create(
      scoped_refptr<KeyProvider> key_provider, Algorithm algorithm);

  /// Encrypt plain |data| for |participant_id| with |key_index|.
  virtual scoped_refptr<EncryptedPacket> encrypt(
      const string participant_id, int key_index, vector<uint8_t> data) = 0;

  /// Decrypt |encrypted_packet| for |participant_id| with |key_index|.
  virtual vector<uint8_t> decrypt(const string participant_id, int key_index,
                                  scoped_refptr<EncryptedPacket> packet) = 0;

 protected:
  virtual ~RTCDataPacketCryptor() {}
};

}  // namespace libwebrtc

#endif  // LIB_RTC_DATA_PACKET_CRYPTOR_H_
