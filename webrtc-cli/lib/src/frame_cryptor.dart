import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'native/ffi/webrtc_c.dart';
import 'rtc_rtp_receiver.dart';
import 'rtc_rtp_sender.dart';

/// FrameCryptor / KeyProvider 状态事件分发。
/// C 侧把 frameCryptionStateChanged 经 factory 事件回调上报(不带 frameCryptorId,
/// 只带 participantId/state), 这里用一个广播统一收, FrameCryptorFfi 按 participantId 关心。
class _FrameCryptorEvents {
  _FrameCryptorEvents._();
  static final _FrameCryptorEvents instance = _FrameCryptorEvents._();

  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _controller.stream;

  /// factory 事件回调把这里发出的原始 frameCryptionStateChanged 播出去。
  void notify(Map<String, dynamic> map) => _controller.add(map);
}

/// 镜像 flutter frame_cryptor_impl.dart 的 KeyProviderImpl, 走 C ABI。
class KeyProviderFfi implements KeyProvider {
  KeyProviderFfi(this._id);
  final String _id;
  @override
  String get id => _id;

  @override
  Future<void> setSharedKey({required Uint8List key, int index = 0}) async {
    WebrtcC.keyProviderSetSharedKey(WebrtcRuntime.instance.factory,
        _json({'keyIndex': index, 'key': key}));
  }

  @override
  Future<Uint8List> ratchetSharedKey({int index = 0}) async {
    final r = WebrtcC.keyProviderRatchetSharedKey(
        WebrtcRuntime.instance.factory, _json({'keyIndex': index}));
    return _bytes(r);
  }

  @override
  Future<Uint8List> exportSharedKey({int index = 0}) async {
    final r = WebrtcC.keyProviderExportSharedKey(
        WebrtcRuntime.instance.factory, _json({'keyIndex': index}));
    return _bytes(r);
  }

  @override
  Future<bool> setKey(
      {required String participantId,
      required int index,
      required Uint8List key}) async {
    final r = WebrtcC.keyProviderSetKey(WebrtcRuntime.instance.factory,
        _json({'keyIndex': index, 'key': key, 'participantId': participantId}));
    return r?['result'] == true;
  }

  @override
  Future<Uint8List> ratchetKey(
      {required String participantId, required int index}) async {
    final r = WebrtcC.keyProviderRatchetKey(WebrtcRuntime.instance.factory,
        _json({'keyIndex': index, 'participantId': participantId}));
    return _bytes(r);
  }

  @override
  Future<Uint8List> exportKey(
      {required String participantId, required int index}) async {
    final r = WebrtcC.keyProviderExportKey(WebrtcRuntime.instance.factory,
        _json({'keyIndex': index, 'participantId': participantId}));
    return _bytes(r);
  }

  @override
  Future<void> setSifTrailer({required Uint8List trailer}) async {
    WebrtcC.keyProviderSetSifTrailer(
        WebrtcRuntime.instance.factory, _json({'sifTrailer': trailer}));
  }

  @override
  Future<void> dispose() async {
    WebrtcC.keyProviderDispose(
        WebrtcRuntime.instance.factory, _json({}));
  }

  String _json(Map<String, dynamic> m) {
    m['keyProviderId'] = _id;
    return _encode(m);
  }
}

/// 镜像 FrameCryptorImpl, 走 C ABI; 状态事件经 _FrameCryptorEvents 路由。
class FrameCryptorFfi extends FrameCryptor {
  FrameCryptorFfi(this._frameCryptorId, this._participantId) {
    _sub = _FrameCryptorEvents.instance.stream
        .where((e) => e['participantId'] == _participantId)
        .listen(_onEvent);
  }
  final String _frameCryptorId;
  final String _participantId;
  StreamSubscription<dynamic>? _sub;

  @override
  String get participantId => _participantId;

  void _onEvent(Map<String, dynamic> map) {
    if (map['event'] != 'frameCryptionStateChanged') return;
    final state = _stateFromString(map['state'] as String? ?? '');
    if (state != null) {
      onFrameCryptorStateChanged?.call(_participantId, state);
    }
  }

  FrameCryptorState? _stateFromString(String str) {
    switch (str) {
      case 'new':
        return FrameCryptorState.FrameCryptorStateNew;
      case 'ok':
        return FrameCryptorState.FrameCryptorStateOk;
      case 'decryptionFailed':
        return FrameCryptorState.FrameCryptorStateDecryptionFailed;
      case 'encryptionFailed':
        return FrameCryptorState.FrameCryptorStateEncryptionFailed;
      case 'internalError':
        return FrameCryptorState.FrameCryptorStateInternalError;
      case 'keyRatcheted':
        return FrameCryptorState.FrameCryptorStateKeyRatcheted;
      case 'missingKey':
        return FrameCryptorState.FrameCryptorStateMissingKey;
    }
    return null;
  }

  @override
  Future<void> updateCodec(String codec) async {
    // 仅 web 需要
  }

  @override
  Future<bool> setKeyIndex(int index) async {
    final r = WebrtcC.frameCryptorSetKeyIndex(WebrtcRuntime.instance.factory,
        _json({'keyIndex': index}));
    return r?['result'] == true;
  }

  @override
  Future<int> get keyIndex async {
    final r = WebrtcC.frameCryptorGetKeyIndex(
        WebrtcRuntime.instance.factory, _json({}));
    return (r?['keyIndex'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    final r = WebrtcC.frameCryptorSetEnabled(
        WebrtcRuntime.instance.factory, _json({'enabled': enabled}));
    return r?['result'] == true;
  }

  @override
  Future<bool> get enabled async {
    final r = WebrtcC.frameCryptorGetEnabled(
        WebrtcRuntime.instance.factory, _json({}));
    return r?['enabled'] == true;
  }

  @override
  Future<void> dispose() async {
    _sub?.cancel();
    _sub = null;
    WebrtcC.frameCryptorDispose(WebrtcRuntime.instance.factory, _json({}));
  }

  String _json(Map<String, dynamic> m) {
    m['frameCryptorId'] = _frameCryptorId;
    return _encode(m);
  }
}

/// 镜像 FrameCryptorFactoryImpl, 全局单例。
/// C ABI 以 pc 句柄创建 frameCryptor, 这个句柄从 sender/receiver.pc 取(同参考取 peerConnectionId)。
class FrameCryptorFactoryFfi implements FrameCryptorFactory {
  FrameCryptorFactoryFfi._();
  static final FrameCryptorFactory instance = FrameCryptorFactoryFfi._();

  @override
  Future<FrameCryptor> createFrameCryptorForRtpSender({
    required String participantId,
    required RTCRtpSender sender,
    required Algorithm algorithm,
    required KeyProvider keyProvider,
  }) async {
    final r = WebrtcC.frameCryptorFactoryCreateFrameCryptor(
        (sender as RTCRtpSenderFfi).pc,
        _encode({
          'type': 'sender',
          'rtpSenderId': sender.senderId,
          'participantId': participantId,
          'keyProviderId': keyProvider.id,
          'algorithm': algorithm.index,
        }));
    final id = r?['frameCryptorId'] as String?;
    if (id == null) throw Exception('createFrameCryptorForRtpSender failed');
    return FrameCryptorFfi(id, participantId);
  }

  @override
  Future<FrameCryptor> createFrameCryptorForRtpReceiver({
    required String participantId,
    required RTCRtpReceiver receiver,
    required Algorithm algorithm,
    required KeyProvider keyProvider,
  }) async {
    final nativeReceiver = receiver as RTCRtpReceiverFfi;
    final r = WebrtcC.frameCryptorFactoryCreateFrameCryptor(
        nativeReceiver.pc,
        _encode({
          'type': 'receiver',
          'rtpReceiverId': nativeReceiver.receiverId,
          'participantId': participantId,
          'keyProviderId': keyProvider.id,
          'algorithm': algorithm.index,
        }));
    final id = r?['frameCryptorId'] as String?;
    if (id == null) throw Exception('createFrameCryptorForRtpReceiver failed');
    return FrameCryptorFfi(id, participantId);
  }

  @override
  Future<KeyProvider> createDefaultKeyProvider(
      KeyProviderOptions options) async {
    final r = WebrtcC.frameCryptorFactoryCreateKeyProvider(
        WebrtcRuntime.instance.factory,
        _encode({'keyProviderOptions': options.toJson()}));
    final id = r?['keyProviderId'] as String?;
    if (id == null) throw Exception('createDefaultKeyProvider failed');
    return KeyProviderFfi(id);
  }
}

// ---- 公共辅助 ----

String _encode(Map<String, dynamic> m) => jsonEncode(m);

/// 把工厂事件回调里的 frameCryptionStateChanged 播给各 FrameCryptorFfi。
void routeFrameCryptorEvent(Map<String, dynamic> map) =>
    _FrameCryptorEvents.instance.notify(map);

Uint8List _bytes(Map<String, dynamic>? r) {
  final v = r?['result'];
  if (v is List) return Uint8List.fromList(v.cast<int>());
  return Uint8List(0);
}
