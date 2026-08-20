import 'dart:convert';
import 'dart:ffi';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track.dart';
import 'native/ffi/webrtc_c.dart';
import 'rtc_rtp_utils.dart';

class _DtmfSenderFfi extends RTCDTMFSender {
  _DtmfSenderFfi(this._pc, this._senderId);
  final Pointer<Void> _pc;
  final String _senderId;

  @override
  Future<void> insertDTMF(String tones,
      {int duration = 100, int interToneGap = 70}) async {
    WebrtcC.pcSenderInsertDtmf(_pc, _senderId, tones, duration, interToneGap);
  }

  @override
  Future<bool> canInsertDtmf() async =>
      WebrtcC.pcSenderCanInsertDtmf(_pc, _senderId);
}

/// 镜像 rtc_rtp_sender_impl.dart 的 RTCRtpSenderNative。
class RTCRtpSenderFfi extends RTCRtpSender {
  RTCRtpSenderFfi(this.senderId, this._track, this._parameters,
      {required Pointer<Void> pc, String? peerConnectionId})
      : _pc = pc,
        _peerConnectionId = peerConnectionId ?? '';

  factory RTCRtpSenderFfi.fromMap(Map<dynamic, dynamic> map,
          {required Pointer<Void> pc, String? peerConnectionId}) {
    final t = map['track'];
    return RTCRtpSenderFfi(
      map['senderId'] as String,
      (t is Map && t.isNotEmpty)
          ? MediaStreamTrackFfi.fromMap(t, ownerTag: peerConnectionId)
          : null,
      rtpParametersFromMap(map['rtpParameters'] as Map<dynamic, dynamic>? ?? {}),
      pc: pc,
      peerConnectionId: peerConnectionId,
    );
  }

  static List<RTCRtpSender> fromMaps(List<dynamic> maps,
          {required Pointer<Void> pc, String? peerConnectionId}) =>
      maps
          .map((e) =>
              RTCRtpSenderFfi.fromMap(e, pc: pc, peerConnectionId: peerConnectionId))
          .toList();

  @override
  final String senderId;
  final Pointer<Void> _pc;
  final String _peerConnectionId;
  MediaStreamTrack? _track;
  RTCRtpParameters _parameters;
  bool _ownsTrack = false;
  final Set<MediaStream> _streams = {};
  RTCDTMFSender get _dtmf => _DtmfSenderFfi(_pc, senderId);

  String get peerConnectionId => _peerConnectionId;

  Pointer<Void> get pc => _pc;

  @override
  MediaStreamTrack? get track => _track;

  @override
  RTCRtpParameters get parameters => _parameters;

  @override
  bool get ownsTrack => _ownsTrack;

  @override
  RTCDTMFSender get dtmfSender => _dtmf;

  @override
  Future<List<StatsReport>> getStats() async {
    final stats = await WebrtcC.pcGetStats(_pc, _track?.id ?? '');
    return stats
        .map((e) => StatsReport(e['id'] as String, e['type'] as String,
            (e['timestamp'] as num?)?.toDouble() ?? 0, e['values'] ?? {}))
        .toList();
  }

  @override
  Future<bool> setParameters(RTCRtpParameters parameters) async {
    _parameters = parameters;
    return WebrtcC.pcSenderSetParameters(
        _pc, senderId, jsonEncode(parameters.toMap()));
  }

  // replaceTrack/setTrack → sender_set_track(内部 set_track); setStreams → sender_set_stream
  @override
  Future<void> replaceTrack(MediaStreamTrack? track) async {
    await WebrtcC.pcSenderSetTrack(_pc, senderId, track?.id);
    _track = track;
  }

  @override
  Future<void> setTrack(MediaStreamTrack? track,
      {bool takeOwnership = true}) async {
    await WebrtcC.pcSenderSetTrack(_pc, senderId, track?.id);
    _track = track;
    _ownsTrack = takeOwnership;
  }

  @override
  Future<void> setStreams(List<MediaStream> streams) async {
    final ids = streams.map((e) => e.id).toList();
    await WebrtcC.pcSenderSetStream(_pc, senderId, jsonEncode(ids));
    _streams.addAll(streams);
  }

  void removeTrackReference() {
    _track = null;
  }

  @override
  Future<void> dispose() async {}
}
