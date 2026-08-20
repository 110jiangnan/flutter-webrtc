import 'dart:convert';
import 'dart:ffi';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'native/ffi/webrtc_c.dart';
import 'rtc_rtp_receiver.dart';
import 'rtc_rtp_sender.dart';
import 'rtc_rtp_utils.dart';

/// 镜像 rtc_rtp_transceiver_impl.dart 的 RTCRtpTransceiverNative。
class RTCRtpTransceiverFfi extends RTCRtpTransceiver {
  RTCRtpTransceiverFfi(this.transceiverId, this.mid, this._direction,
      this.sender, this.receiver,
      {required Pointer<Void> pc, String? peerConnectionId})
      : _pc = pc,
        _peerConnectionId = peerConnectionId ?? '';

  factory RTCRtpTransceiverFfi.fromMap(Map<dynamic, dynamic> map,
          {required Pointer<Void> pc, String? peerConnectionId}) =>
      RTCRtpTransceiverFfi(
        map['transceiverId'] as String,
        map['mid'] as String? ?? '',
        transceiverDirectionForString(map['direction'] as String?),
        RTCRtpSenderFfi.fromMap(map['sender'] ?? {},
            pc: pc, peerConnectionId: peerConnectionId),
        RTCRtpReceiverFfi.fromMap(map['receiver'] ?? {},
            pc: pc, peerConnectionId: peerConnectionId),
        pc: pc,
        peerConnectionId: peerConnectionId,
      );

  static List<RTCRtpTransceiver> fromMaps(List<dynamic> maps,
          {required Pointer<Void> pc, String? peerConnectionId}) =>
      maps
          .map((e) => RTCRtpTransceiverFfi.fromMap(e,
              pc: pc, peerConnectionId: peerConnectionId))
          .toList();

  @override
  final String transceiverId;
  @override
  final String mid;
  @override
  final RTCRtpSender sender;
  @override
  final RTCRtpReceiver receiver;
  final Pointer<Void> _pc;
  final String _peerConnectionId;
  TransceiverDirection? _direction;
  bool _stoped = false;

  String get peerConnectionId => _peerConnectionId;

  @override
  bool get stoped => _stoped;

  @override
  Future<TransceiverDirection?> getCurrentDirection() async {
    final dir = await WebrtcC.pcTransceiverGetCurrentDirection(_pc, transceiverId);
    if (dir.isEmpty) return null;
    return transceiverDirectionForString(dir);
  }

  @override
  Future<TransceiverDirection> getDirection() async {
    final current = await getCurrentDirection();
    if (current != null) _direction = current;
    return _direction ?? TransceiverDirection.Inactive;
  }

  @override
  Future<void> setDirection(TransceiverDirection direction) async {
    await WebrtcC.pcTransceiverSetDirection(
        _pc, transceiverId, _directionToString(direction));
    _direction = direction;
  }

  static String _directionToString(TransceiverDirection d) {
    switch (d) {
      case TransceiverDirection.SendRecv:
        return 'sendrecv';
      case TransceiverDirection.SendOnly:
        return 'sendonly';
      case TransceiverDirection.RecvOnly:
        return 'recvonly';
      case TransceiverDirection.Stopped:
        return 'stoped';
      case TransceiverDirection.Inactive:
        return 'inactive';
    }
  }

  @override
  Future<void> setCodecPreferences(
      List<RTCRtpCodecCapability> codecs) async {
    WebrtcC.pcTransceiverSetCodecPreferences(
        _pc, transceiverId, jsonEncode(codecs.map((e) => e.toMap()).toList()));
  }

  @override
  Future<void> stop() async {
    await WebrtcC.pcTransceiverStop(_pc, transceiverId);
    _stoped = true;
    _direction = TransceiverDirection.Stopped;
  }
}
