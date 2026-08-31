part of 'webrtc_c.dart';

/// FFI 桥 — data channel 域。
/// 创建 + 事件回调 + 收发 + bufferedAmount + 关闭。
class WebrtcCDataChannel {
  WebrtcCDataChannel._();

  static final DynamicLibrary _lib = loadWebrtcLibrary('data');

  static final _createDataChannel = _lib.lookupFunction<_CreateDataChannelNative,
      _CreateDataChannelNative>('webrtc_create_data_channel');
  static final _dataChannelSetCallback = _lib.lookupFunction<
      _DataChannelSetCallbackNative,
      _DataChannelSetCallbackDart>('webrtc_data_channel_set_callback');
  static final _dataChannelSend = _lib.lookupFunction<_DataChannelSendNative,
      _DataChannelSendDart>('webrtc_data_channel_send');
  static final _dataChannelBufferedAmount = _lib.lookupFunction<
      _DataChannelBufferedAmountNative,
      _DataChannelBufferedAmountNative>('webrtc_data_channel_buffered_amount');
  static final _dataChannelClose = _lib.lookupFunction<_DataChannelCloseNative, _DataChannelCloseDart>('webrtc_data_channel_close');
  static final _freeString = _lib
      .lookupFunction<_FreeStringNative, _FreeStringDart>('webrtc_free_string');

  static String? _takeString(Pointer<Utf8> ptr) =>
      takeStringFrom(ptr, _freeString);

  static Map<String, dynamic>? createDataChannel(
      Pointer<Void> pc, String label, String initJson) {
    final l = label.toNativeUtf8();
    final i = initJson.toNativeUtf8();
    try {
      final ptr = _createDataChannel(pc, l, i);
      final json = _takeString(ptr);
      return json == null ? null : decodeJson(json);
    } finally {
      malloc.free(l);
      malloc.free(i);
    }
  }

  static int dataChannelSetCallback(
      Pointer<Void> factory, String flutterId, int eventIndex) {
    final f = flutterId.toNativeUtf8();
    try {
      return _dataChannelSetCallback(factory, f,
          EventBus.eventCallable.nativeFunction, EventBus.userDataFor(eventIndex));
    } finally {
      malloc.free(f);
    }
  }

  static int dataChannelSend(
      Pointer<Void> factory, String flutterId, bool isBinary, Uint8List data) {
    final f = flutterId.toNativeUtf8();
    final ptr = malloc.allocate<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _dataChannelSend(
          factory, f, isBinary ? 1 : 0, ptr, data.length);
    } finally {
      malloc.free(f);
      malloc.free(ptr);
    }
  }

  static int dataChannelBufferedAmount(
      Pointer<Void> factory, String flutterId) {
    final f = flutterId.toNativeUtf8();
    try {
      final ptr = _dataChannelBufferedAmount(factory, f);
      final json = _takeString(ptr);
      return json == null ? 0 : ((decodeJson(json)['bufferedAmount'] as num?) ?? 0).toInt();
    } finally {
      malloc.free(f);
    }
  }

  static void dataChannelClose(Pointer<Void> factory, String flutterId) {
    final f = flutterId.toNativeUtf8();
    try {
      _dataChannelClose(factory, f);
    } finally {
      malloc.free(f);
    }
  }
}
