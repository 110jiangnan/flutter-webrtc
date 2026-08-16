import 'dart:ffi';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track.dart';
import 'native/ffi/webrtc_c.dart';
import 'rtc_rtp_utils.dart';

/// 镜像 rtc_rtp_receiver_impl.dart 的 RTCRtpReceiverNative。
class RTCRtpReceiverFfi extends RTCRtpReceiver {
  RTCRtpReceiverFfi(this.receiverId, this._track, this._parameters,
      {required Pointer<Void> pc, String? peerConnectionId})
      : _pc = pc,
        _peerConnectionId = peerConnectionId ?? '';

  factory RTCRtpReceiverFfi.fromMap(Map<dynamic, dynamic> map,
          {required Pointer<Void> pc, String? peerConnectionId}) {
    final t = map['track'];
    return RTCRtpReceiverFfi(
      map['receiverId'] as String,
      (t is Map && t.isNotEmpty)
          ? MediaStreamTrackFfi.fromMap(t, ownerTag: peerConnectionId)
          : null,
      rtpParametersFromMap(map['rtpParameters'] as Map<dynamic, dynamic>? ?? {}),
      pc: pc,
      peerConnectionId: peerConnectionId,
    );
  }

  static List<RTCRtpReceiver> fromMaps(List<dynamic> maps,
          {required Pointer<Void> pc, String? peerConnectionId}) =>
      maps
          .map((e) => RTCRtpReceiverFfi.fromMap(e,
              pc: pc, peerConnectionId: peerConnectionId))
          .toList();

  @override
  final String receiverId;
  final Pointer<Void> _pc;
  final String _peerConnectionId;
  final MediaStreamTrack? _track;
  final RTCRtpParameters _parameters;

  String get peerConnectionId => _peerConnectionId;

  @override
  MediaStreamTrack? get track => _track;

  @override
  RTCRtpParameters get parameters => _parameters;

  @override
  Future<List<StatsReport>> getStats() async {
    final stats = await WebrtcC.pcGetStats(_pc, _track?.id ?? '');
    return stats
        .map((e) => StatsReport(e['id'] as String, e['type'] as String,
            (e['timestamp'] as num?)?.toDouble() ?? 0, e['values'] ?? {}))
        .toList();
  }
}
