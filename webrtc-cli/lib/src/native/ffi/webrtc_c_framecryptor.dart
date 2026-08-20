part of 'webrtc_c.dart';

/// FFI 桥 — E2EE 帧加密(FrameCryptor / KeyProvider)。
/// 对齐 flutter_frame_cryptor。所有方法签名一致: (factory, constraintsJson) → JSON。
/// 状态事件 frameCryptionStateChanged 经 factory 事件回调由上层路由。
class WebrtcCFrameCryptor {
  WebrtcCFrameCryptor._();

  static final DynamicLibrary _lib = loadWebrtcLibrary();

  static final _createFrameCryptor = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_frame_cryptor_factory_create_frame_cryptor');
  static final _setKeyIndex = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_frame_cryptor_set_key_index');
  static final _getKeyIndex = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_frame_cryptor_get_key_index');
  static final _setEnabled = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_frame_cryptor_set_enabled');
  static final _getEnabled = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_frame_cryptor_get_enabled');
  static final _dispose = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_frame_cryptor_dispose');
  static final _createKeyProvider = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_frame_cryptor_factory_create_key_provider');
  static final _setSharedKey = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_set_shared_key');
  static final _ratchetSharedKey = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_ratchet_shared_key');
  static final _exportSharedKey = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_export_shared_key');
  static final _setKey = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_set_key');
  static final _ratchetKey = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_ratchet_key');
  static final _exportKey = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_export_key');
  static final _setSifTrailer = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_set_sif_trailer');
  static final _keyProviderDispose = _lib.lookupFunction<_FrameCryptorCallNative,
      _FrameCryptorCallNative>('webrtc_key_provider_dispose');
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

  // ---- FrameCryptor ----
  // createFrameCryptor 以 pc 句柄为第一个参数(见 webrtc.h)
  static Map<String, dynamic>? factoryCreateFrameCryptor(
      Pointer<Void> pc, String constraintsJson) {
    final c = constraintsJson.toNativeUtf8();
    try {
      final ptr = _createFrameCryptor(pc, c);
      final json = takeStringFrom(ptr, _freeString);
      return json == null ? null : decodeJson(json);
    } finally {
      malloc.free(c);
    }
  }
  static Map<String, dynamic>? setKeyIndex(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_setKeyIndex, factory, constraintsJson);
  static Map<String, dynamic>? getKeyIndex(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_getKeyIndex, factory, constraintsJson);
  static Map<String, dynamic>? setEnabled(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_setEnabled, factory, constraintsJson);
  static Map<String, dynamic>? getEnabled(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_getEnabled, factory, constraintsJson);
  static Map<String, dynamic>? dispose(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_dispose, factory, constraintsJson);

  // ---- KeyProvider ----
  static Map<String, dynamic>? factoryCreateKeyProvider(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_createKeyProvider, factory, constraintsJson);
  static Map<String, dynamic>? setSharedKey(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_setSharedKey, factory, constraintsJson);
  static Map<String, dynamic>? ratchetSharedKey(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_ratchetSharedKey, factory, constraintsJson);
  static Map<String, dynamic>? exportSharedKey(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_exportSharedKey, factory, constraintsJson);
  static Map<String, dynamic>? setKey(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_setKey, factory, constraintsJson);
  static Map<String, dynamic>? ratchetKey(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_ratchetKey, factory, constraintsJson);
  static Map<String, dynamic>? exportKey(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_exportKey, factory, constraintsJson);
  static Map<String, dynamic>? setSifTrailer(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_setSifTrailer, factory, constraintsJson);
  static Map<String, dynamic>? keyProviderDispose(
          Pointer<Void> factory, String constraintsJson) =>
      _call(_keyProviderDispose, factory, constraintsJson);
}
