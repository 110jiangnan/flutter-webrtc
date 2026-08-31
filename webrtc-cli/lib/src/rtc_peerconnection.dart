import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream.dart';
import 'media_stream_track.dart';
import 'native/ffi/webrtc_c.dart';
import 'rtc_data_channel.dart';
import 'rtc_rtp_receiver.dart';
import 'rtc_rtp_sender.dart';
import 'rtc_rtp_transceiver.dart';

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

  void _handleEvent(String json, Uint8List? binary) {
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
        // 与 flutter-webrtc 对齐: 远端通道出现即视为 Open, 否则在等
        // dataChannelStateChanged 时可能因通道已提前 Open 而永久收不到状态事件
        final dc = RTCDataChannelFfi.fromMap(map,
            state: RTCDataChannelState.RTCDataChannelOpen);
        dc.attach();
        onDataChannel?.call(dc);
        // 补触发一次 Open 状态回调: 对端创建的 channel 在 delegate 挂上时已 Open,
        // 原生不会再发 dataChannelStateChanged, 上层(onDataChannelState 监听方,
        // 如被控端 FileContext.onDataChannel)会因永远收不到 Open 而认为通道未连上。
        // 先于 onDataChannel 通知不行(上层要在 onDataChannel 里挂 onDataChannelState),
        // 所以这里在 call(onDataChannel) 之后补发。
        if (dc.onDataChannelState != null) {
          dc.onDataChannelState!(RTCDataChannelState.RTCDataChannelOpen);
        }
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
    await WebrtcC.pcSetConfiguration(_pc, jsonEncode(configuration));
    _configuration.clear();
    _configuration.addAll(configuration);
  }

  @override
  Future<RTCSessionDescription> createOffer(
      [Map<String, dynamic>? constraints]) async {
    final json =
        await WebrtcC.pcCreateOffer(_pc, jsonEncode(constraints ?? const {}));
    return RTCSessionDescription(
        json['sdp'] as String, json['type'] as String);
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
  Future<RTCSessionDescription?> getLocalDescription() async {
    final json = await WebrtcC.pcGetLocalDescription(_pc);
    return _sdpOrNull(json);
  }

  @override
  Future<RTCSessionDescription?> getRemoteDescription() async {
    final json = await WebrtcC.pcGetRemoteDescription(_pc);
    return _sdpOrNull(json);
  }

  RTCSessionDescription? _sdpOrNull(Map<String, dynamic> json) {
    final sdp = json['sdp'] as String?;
    final type = json['type'] as String?;
    if (sdp == null || sdp.isEmpty) return null;
    return RTCSessionDescription(sdp, type ?? '');
  }

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
  Future<void> restartIce() async {
    WebrtcC.pcRestartIce(_pc);
  }

  @override
  Future<void> close() async {
    WebrtcC.pcClose(_pc);
  }

  @override
  RTCDTMFSender createDtmfSender(MediaStreamTrack track) {
    final senders = WebrtcC.pcGetSenders(_pc);
    for (final s in senders) {
      final t = (s as Map)['track'];
      if (t is Map && (t['id'] == track.id)) {
        return _DtmfSenderFfi(_pc, s['senderId'] as String);
      }
    }
    return _DtmfSenderFfi(_pc, '');
  }

  @override
  Future<List<RTCRtpSender>> getSenders() async {
    return RTCRtpSenderFfi.fromMaps(WebrtcC.pcGetSenders(_pc), pc: _pc);
  }

  @override
  Future<List<RTCRtpReceiver>> getReceivers() async {
    return RTCRtpReceiverFfi.fromMaps(WebrtcC.pcGetReceivers(_pc), pc: _pc);
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
    Map<String, dynamic> initMap = const {};
    if (init != null) {
      initMap = {
        if (init.direction != null)
          'direction': _directionToString(init.direction!),
        if (init.streams != null)
          'streamIds': init.streams!.map((e) => e.id).toList(),
        if (init.sendEncodings != null)
          'sendEncodings':
              init.sendEncodings!.map((e) => e.toMap()).toList(),
      };
    }
    final response = WebrtcC.pcAddTransceiver(
        _pc,
        track?.id,
        kind == null ? '' : _mediaTypeToString(kind),
        jsonEncode(initMap));
    if (response == null) {
      throw Exception('addTransceiver failed');
    }
    return RTCRtpTransceiverFfi.fromMap(response, pc: _pc);
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

  static String _mediaTypeToString(RTCRtpMediaType kind) {
    switch (kind) {
      case RTCRtpMediaType.RTCRtpMediaTypeAudio:
        return 'audio';
      case RTCRtpMediaType.RTCRtpMediaTypeVideo:
        return 'video';
      case RTCRtpMediaType.RTCRtpMediaTypeData:
        return 'data';
    }
  }

  @override
  Future<void> addStream(MediaStream stream) async {
    WebrtcC.pcAddStream(_pc, stream.id);
  }

  @override
  Future<void> removeStream(MediaStream stream) async {
    WebrtcC.pcRemoveStream(_pc, stream.id);
  }
}
