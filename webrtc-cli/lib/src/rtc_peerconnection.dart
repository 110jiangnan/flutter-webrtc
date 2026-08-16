import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream.dart';
import 'media_stream_track.dart';
import 'native/ffi/webrtc_c.dart';
import 'rtc_data_channel.dart';
import 'rtc_rtp_receiver.dart';
import 'rtc_rtp_sender.dart';
import 'rtc_rtp_transceiver.dart';

class _StubDtmfSender extends RTCDTMFSender {
  @override
  Future<void> insertDTMF(String tones,
      {int duration = 100, int interToneGap = 70}) async {}

  @override
  Future<bool> canInsertDtmf() async => false;
}

/// 镜像 rtc_peerconnection_impl.dart 的 RTCPeerConnectionNative。
class RTCPeerConnectionFfi extends RTCPeerConnection {
  /// eventIndex 由 createPeerConnection 先 reserve(create 时作 user_data), 这里 bind。
  RTCPeerConnectionFfi(this._pc, this._configuration, {required int eventIndex})
      : _eventIndex = eventIndex {
    WebrtcC.bindEventHandler(_eventIndex!, _handleEvent);
  }

  final Pointer<Void> _pc;
  final Map<String, dynamic> _configuration;
  int? _eventIndex;

  final List<MediaStream> _localStreams = [];
  final List<MediaStream> _remoteStreams = [];

  RTCSignalingState? _signalingState;
  RTCIceGatheringState? _iceGatheringState;
  RTCIceConnectionState? _iceConnectionState;
  RTCPeerConnectionState? _connectionState;

  @override
  RTCSignalingState? get signalingState => _signalingState;
  @override
  RTCIceGatheringState? get iceGatheringState => _iceGatheringState;
  @override
  RTCIceConnectionState? get iceConnectionState => _iceConnectionState;
  @override
  RTCPeerConnectionState? get connectionState => _connectionState;
  @override
  Map<String, dynamic> get getConfiguration => _configuration;

  void _handleEvent(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    switch (map['event']) {
      case 'signalingState':
        _signalingState = signalingStateForString(map['state'] as String);
        onSignalingState?.call(_signalingState!);
        break;
      case 'peerConnectionState':
        _connectionState = peerConnectionStateForString(map['state'] as String);
        onConnectionState?.call(_connectionState!);
        break;
      case 'iceGatheringState':
        _iceGatheringState = iceGatheringStateforString(map['state'] as String);
        onIceGatheringState?.call(_iceGatheringState!);
        break;
      case 'iceConnectionState':
        _iceConnectionState = iceConnectionStateForString(map['state'] as String);
        onIceConnectionState?.call(_iceConnectionState!);
        break;
      case 'onCandidate':
        final cand = map['candidate'];
        onIceCandidate?.call(RTCIceCandidate(
            cand['candidate'], cand['sdpMid'], cand['sdpMLineIndex']));
        break;
      case 'onAddStream':
        final streamId = map['streamId'] as String;
        var stream = _remoteStreams.firstWhere((it) => it.id == streamId,
            orElse: () {
          final newStream = MediaStreamFfi(streamId, '');
          newStream.setMediaTracks(map['audioTracks'], map['videoTracks']);
          return newStream;
        });
        onAddStream?.call(stream);
        if (!_remoteStreams.contains(stream)) _remoteStreams.add(stream);
        break;
      case 'onRemoveStream':
        final streamId = map['streamId'] as String;
        for (final item in _remoteStreams) {
          if (item.id == streamId) {
            onRemoveStream?.call(item);
            break;
          }
        }
        _remoteStreams.removeWhere((it) => it.id == streamId);
        break;
      case 'onAddTrack':
        final streamId = map['streamId'] as String;
        final track = MediaStreamTrackFfi.fromMap(map['track']);
        final stream = _remoteStreams.firstWhere((it) => it.id == streamId,
            orElse: () {
          final newStream = MediaStreamFfi(streamId, '');
          _remoteStreams.add(newStream);
          return newStream;
        });
        final oldTracks = track.kind == 'audio'
            ? stream.getAudioTracks()
            : stream.getVideoTracks();
        final oldTrack = oldTracks.isNotEmpty ? oldTracks[0] : null;
        if (oldTrack != null) {
          stream.removeTrack(oldTrack, removeFromNative: false);
          onRemoveTrack?.call(stream, oldTrack);
        }
        stream.addTrack(track, addToNative: false);
        onAddTrack?.call(stream, track);
        break;
      case 'onRemoveTrack':
        final trackId = map['trackId'] as String;
        for (final stream in _remoteStreams) {
          for (final track in stream.getTracks()) {
            if (track.id == trackId) {
              onRemoveTrack?.call(stream, track);
              stream.removeTrack(track, removeFromNative: false);
              return;
            }
          }
        }
        break;
      case 'didOpenDataChannel':
        final dc = RTCDataChannelFfi.fromMap(map);
        dc.attach();
        onDataChannel?.call(dc);
        break;
      case 'onRenegotiationNeeded':
        onRenegotiationNeeded?.call();
        break;
      case 'onTrack':
        final streams = (map['streams'] as List<dynamic>? ?? [])
            .map((e) => MediaStreamFfi.fromMap(e as Map<dynamic, dynamic>))
            .toList();
        final receiver = RTCRtpReceiverFfi.fromMap(map['receiver'], pc: _pc);
        final track = MediaStreamTrackFfi.fromMap(map['track']);
        final transceiver = map['transceiver'] != null
            ? RTCRtpTransceiverFfi.fromMap(map['transceiver'], pc: _pc)
            : null;
        onTrack?.call(RTCTrackEvent(
            receiver: receiver,
            track: track,
            streams: streams,
            transceiver: transceiver));
        break;
    }
  }

  @override
  Future<void> dispose() async {
    if (_eventIndex != null) {
      WebrtcC.unregisterEventHandler(_eventIndex!);
      _eventIndex = null;
    }
    WebrtcC.pcDestroy(_pc);
  }

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {
    _configuration.clear();
    _configuration.addAll(configuration);
  }

  @override
  Future<RTCSessionDescription> createOffer(
      [Map<String, dynamic>? constraints]) async {
    throw UnimplementedError('被控端不创建 offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer(
      [Map<String, dynamic>? constraints]) async {
    final json = await WebrtcC.pcCreateAnswer(
        _pc, jsonEncode(constraints ?? const {}));
    return RTCSessionDescription(
        json['sdp'] as String, json['type'] as String);
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    await WebrtcC.pcSetLocalDescription(_pc, description.sdp!, description.type!);
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    await WebrtcC.pcSetRemoteDescription(
        _pc, description.sdp!, description.type!);
  }

  @override
  Future<RTCSessionDescription?> getLocalDescription() async => null;

  @override
  Future<RTCSessionDescription?> getRemoteDescription() async => null;

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    WebrtcC.pcAddIceCandidate(_pc, jsonEncode(candidate.toMap()));
  }

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async {
    final stats = await WebrtcC.pcGetStats(_pc, track?.id ?? '');
    return stats
        .map((e) => StatsReport(e['id'] as String, e['type'] as String,
            (e['timestamp'] as num?)?.toDouble() ?? 0, e['values'] ?? {}))
        .toList();
  }

  @override
  List<MediaStream?> getLocalStreams() => _localStreams;

  @override
  List<MediaStream?> getRemoteStreams() => _remoteStreams;

  @override
  Future<RTCDataChannel> createDataChannel(
      String label, RTCDataChannelInit dataChannelDict) async {
    final response = WebrtcC.createDataChannel(
        _pc, label, jsonEncode(dataChannelDict.toMap()));
    if (response == null) {
      throw Exception('createDataChannel failed');
    }
    final dc = RTCDataChannelFfi.fromMap(response);
    dc.attach();
    return dc;
  }

  @override
  Future<void> restartIce() async {}

  @override
  Future<void> close() async {
    WebrtcC.pcClose(_pc);
  }

  @override
  RTCDTMFSender createDtmfSender(MediaStreamTrack track) =>
      _StubDtmfSender();

  @override
  Future<List<RTCRtpSender>> getSenders() async {
    return RTCRtpSenderFfi.fromMaps(WebrtcC.pcGetSenders(_pc), pc: _pc);
  }

  @override
  Future<List<RTCRtpReceiver>> getReceivers() async {
    // C ABI 未实现 getReceivers(被控是发送方), 返回空
    return const [];
  }

  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async {
    return RTCRtpTransceiverFfi.fromMaps(
        WebrtcC.pcGetTransceivers(_pc), pc: _pc);
  }

  @override
  Future<RTCRtpSender> addTrack(MediaStreamTrack track,
      [MediaStream? stream]) async {
    final response = WebrtcC.pcAddTrack(_pc, track.id!, stream?.id);
    if (response == null) {
      throw Exception('addTrack failed');
    }
    return RTCRtpSenderFfi.fromMap(response, pc: _pc);
  }

  @override
  Future<bool> removeTrack(RTCRtpSender sender) async {
    return WebrtcC.pcRemoveTrack(_pc, sender.senderId);
  }

  @override
  Future<RTCRtpTransceiver> addTransceiver(
      {MediaStreamTrack? track,
      RTCRtpMediaType? kind,
      RTCRtpTransceiverInit? init}) async {
    // C ABI 未实现 AddTransceiver(被控发送用 addTrack), 抛未实现
    throw UnimplementedError('addTransceiver: 被控发送用 addTrack');
  }

  @override
  Future<void> addStream(MediaStream stream) async {}

  @override
  Future<void> removeStream(MediaStream stream) async {}
}
