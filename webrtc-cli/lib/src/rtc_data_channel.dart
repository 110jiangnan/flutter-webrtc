import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'native/ffi/webrtc_c.dart';

/// 镜像 rtc_data_channel_impl.dart 的 RTCDataChannelNative。
class RTCDataChannelFfi extends RTCDataChannel {
  RTCDataChannelFfi(this._id, this._label, this.flutterId) {
    _stateChangeController =
        StreamController<RTCDataChannelState>.broadcast(sync: true);
    _messageController =
        StreamController<RTCDataChannelMessage>.broadcast(sync: true);
    stateChangeStream = _stateChangeController.stream;
    messageStream = _messageController.stream;
  }

  factory RTCDataChannelFfi.fromMap(Map<dynamic, dynamic> map) =>
      RTCDataChannelFfi((map['id'] as num?)?.toInt() ?? 0,
          map['label'] as String? ?? '', map['flutterId'] as String? ?? '');

  final int _id;
  final String _label;
  final String flutterId;

  late final StreamController<RTCDataChannelState> _stateChangeController;
  late final StreamController<RTCDataChannelMessage> _messageController;

  RTCDataChannelState? _state;
  int? _bufferedAmount = 0;
  int? _eventIndex;

  @override
  int? get id => _id;

  @override
  String? get label => _label;

  @override
  RTCDataChannelState? get state => _state;

  @override
  int? get bufferedAmount => _bufferedAmount;

  /// 注册事件回调, 由 createDataChannel / didOpenDataChannel 调用。
  void attach() {
    if (_eventIndex != null) return;
    _eventIndex = WebrtcC.registerEventHandler(_handleEvent);
    WebrtcC.dataChannelSetCallback(
        WebrtcRuntime.instance.factory, flutterId, _eventIndex!);
  }

  void _handleEvent(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    switch (map['event']) {
      case 'dataChannelStateChanged':
        _state = rtcDataChannelStateForString(map['state'] as String);
        onDataChannelState?.call(_state!);
        _stateChangeController.add(_state!);
        break;
      case 'dataChannelReceiveMessage':
        final isBinary = map['type'] == 'binary';
        final data = map['data'] as String;
        final message = isBinary
            ? RTCDataChannelMessage.fromBinary(base64Decode(data))
            : RTCDataChannelMessage(data);
        onMessage?.call(message);
        _messageController.add(message);
        break;
    }
  }

  @override
  Future<int> getBufferedAmount() async {
    _bufferedAmount =
        WebrtcC.dataChannelBufferedAmount(WebrtcRuntime.instance.factory, flutterId);
    return _bufferedAmount!;
  }

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    if (message.isBinary) {
      WebrtcC.dataChannelSend(
          WebrtcRuntime.instance.factory, flutterId, true, message.binary);
    } else {
      WebrtcC.dataChannelSend(WebrtcRuntime.instance.factory, flutterId, false,
          Uint8List.fromList(utf8.encode(message.text)));
    }
  }

  @override
  Future<void> close() async {
    if (_eventIndex != null) {
      WebrtcC.unregisterEventHandler(_eventIndex!);
      _eventIndex = null;
    }
    await _stateChangeController.close();
    await _messageController.close();
    WebrtcC.dataChannelClose(WebrtcRuntime.instance.factory, flutterId);
  }
}
