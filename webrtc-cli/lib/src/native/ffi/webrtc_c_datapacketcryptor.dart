part of 'webrtc_c.dart';

/// FFI 桥 — data channel 包 E2EE(DataPacketCryptor)。
/// 对齐 flutter_data_packet_cryptor。所有方法签名一致: (factory, constraintsJson) → JSON。
/// 复用 FrameCryptor 创建的 KeyProvider(keyProviderId), 见 webrtc.h。
class WebrtcCDataPacketCryptor {
  WebrtcCDataPacketCryptor._();

  static final DynamicLibrary _lib = loadWebrtcLibrary('datapacketcrypto');

  static final _create = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_data_packet_cryptor_create');
  static final _dispose = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_data_packet_cryptor_dispose');
  static final _encrypt = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_data_packet_cryptor_encrypt');
  static final _decrypt = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_data_packet_cryptor_decrypt');
  static final _freeString = _lib
      .lookupFunction<_FreeStringNative, _FreeStringDart>('webrtc_free_string');

  static Map<String, dynamic>? _call(
      _FrameCryptorCallNative fn, Pointer<Void> factory, String constraintsJson) {
    final c = constraintsJson.toNativeUtf8();
    try {
      final ptr = fn(factory, c);
      final json = takeStringFrom(ptr, _freeString);
      return json == null ? null : decodeJson(json);
    } finally {
      malloc.free(c);
    }
  }

  // ---- DataPacketCryptor ----
  static Map<String, dynamic>? create(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_create, factory, constraintsJson);
  static Map<String, dynamic>? dispose(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_dispose, factory, constraintsJson);
  static Map<String, dynamic>? encrypt(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_encrypt, factory, constraintsJson);
  static Map<String, dynamic>? decrypt(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_decrypt, factory, constraintsJson);
}
