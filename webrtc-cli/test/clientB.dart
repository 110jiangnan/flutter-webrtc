import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webrtc_cli/webrtc_cli.dart';

final _log = (String tag, String msg) => print('[${DateTime.now().toIso8601String()}] [$tag] $msg');

/// 接收端/主控端: 接收 A 的所有共享, 显示 DataChannel 消息。
class ClientB {
  RTCPeerConnection? _pc;
  final List<MediaStream> _remoteStreams = [];
  RTCDataChannel? _dc;

  Timer? _statsTimer;
  int _bytesSent = 0;
  int _bytesReceived = 0;

  final List<RTCIceCandidate> pendingCandidates = [];
  Completer<void>? _iceGatherDone;

  bool _connected = false;
  Completer<void>? _connectDone;

  // 接收系统音频的独立 PC(普通 factory; 接收端不涉及 custom source 推帧, 无需 isSysAudio)
  RTCPeerConnection? _sysAudioPc;
  final List<RTCIceCandidate> sysAudioPendingCandidates = [];
  Completer<void>? _sysAudioIceGatherDone;
  Completer<void>? _sysAudioConnectDone;
  bool _sysAudioConnected = false;

  // DataChannel 消息日志
  final List<String> dcMessagesReceived = [];
  final List<Uint8List> dcBinaryReceived = [];

  Future<void> start() async {
    _log('B', '=== 开始初始化接收端 ===');

    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _log('B', 'PeerConnection 已创建');

    _pc!.onIceCandidate = _onIceCandidate;
    _pc!.onIceGatheringState = _onIceGatheringState;
    _pc!.onIceConnectionState = _onIceConnectionState;
    _pc!.onConnectionState = _onConnectionState;
    _pc!.onSignalingState = _onSignalingState;
    _pc!.onDataChannel = _onDataChannel;
    _pc!.onTrack = _onTrack;
    _pc!.onAddStream = _onAddStream;
    _pc!.onRemoveStream = _onRemoveStream;

    // 系统音频接收 PC
    _sysAudioPc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _sysAudioPc!.onIceCandidate = _onSysAudioIceCandidate;
    _sysAudioPc!.onIceGatheringState = _onSysAudioIceGatheringState;
    _sysAudioPc!.onIceConnectionState = _onSysAudioIceConnectionState;
    _log('B', '系统音频接收 PC 已创建');

    _log('B', '=== 接收端初始化完成 ===');
  }

  Future<void> setRemoteDescription(RTCSessionDescription desc) async {
    _connectDone = Completer<void>();
    await _pc!.setRemoteDescription(desc);
    _log('B', 'RemoteDescription 已设置 type=${desc.type}');
  }

  Future<RTCSessionDescription> createAnswer() async {
    _log('B', '创建 Answer...');
    final answer = await _pc!.createAnswer();
    _log('B', 'Answer 已创建 type=${answer.type}');
    return answer;
  }

  Future<void> setLocalDescription(RTCSessionDescription desc) async {
    _iceGatherDone = Completer<void>();
    await _pc!.setLocalDescription(desc);
    _log('B', 'LocalDescription 已设置 type=${desc.type}');
  }

  Future<void> addRemoteCandidate(RTCIceCandidate c) async {
    await _pc!.addCandidate(c);
    _log('B', '已添加远端 ICE candidate: ${c.candidate?.substring(0, (c.candidate?.length ?? 0).clamp(0, 60))}...');
  }

  Future<void> waitIceGathering() => _iceGatherDone?.future ?? Future.value();
  Future<void> waitConnected() => _connectDone?.future ?? Future.value();

  /// 是否创建了系统音频接收 PC
  bool get hasSysAudioPc => _sysAudioPc != null;

  // ---- 系统音频接收 PC ----

  Future<void> setSysAudioRemoteDescription(RTCSessionDescription desc) async {
    _sysAudioConnectDone = Completer<void>();
    await _sysAudioPc!.setRemoteDescription(desc);
    _log('B', '系统音频 RemoteDescription 已设置');
  }

  Future<RTCSessionDescription> createSysAudioAnswer() async {
    final answer = await _sysAudioPc!.createAnswer();
    _log('B', '系统音频 Answer 已创建');
    return answer;
  }

  Future<void> setSysAudioLocalDescription(RTCSessionDescription desc) async {
    _sysAudioIceGatherDone = Completer<void>();
    await _sysAudioPc!.setLocalDescription(desc);
    _log('B', '系统音频 LocalDescription 已设置');
  }

  Future<void> addSysAudioRemoteCandidate(RTCIceCandidate c) async {
    await _sysAudioPc!.addCandidate(c);
    _log('B',
        '系统音频已添加远端 candidate: ${c.candidate?.substring(0, (c.candidate?.length ?? 0).clamp(0, 60))}...');
  }

  Future<void> waitSysAudioIceGathering() =>
      _sysAudioIceGatherDone?.future ?? Future.value();

  Future<void> waitSysAudioConnected() =>
      _sysAudioConnectDone?.future ?? Future.value();

  void _onSysAudioIceCandidate(RTCIceCandidate candidate) {
    sysAudioPendingCandidates.add(candidate);
  }

  void _onSysAudioIceGatheringState(RTCIceGatheringState state) {
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      _sysAudioIceGatherDone?.complete();
    }
  }

  void _onSysAudioIceConnectionState(RTCIceConnectionState state) {
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected &&
        !_sysAudioConnected) {
      _sysAudioConnected = true;
      _sysAudioConnectDone?.complete();
    }
  }

  Future<void> sendDcString(String text) async {
    if (_dc == null) {
      _log('B', 'DC 未就绪, 无法发送');
      return;
    }
    _dc!.send(RTCDataChannelMessage(text));
    _log('B', 'DC 发送字符串: "$text"');
  }

  Future<void> sendDcBinary(Uint8List data) async {
    if (_dc == null) {
      _log('B', 'DC 未就绪, 无法发送');
      return;
    }
    _dc!.send(RTCDataChannelMessage.fromBinary(data));
    _log('B', 'DC 发送二进制: ${data.length} bytes');
  }

  // ---- Stats ----

  void _startStatsTimer() {
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) => _printStats());
  }

  Future<void> _printStats() async {
    if (_pc == null) return;
    try {
      final stats = await _pc!.getStats();
      int totalBytesSent = 0;
      int totalBytesReceived = 0;
      int candidateBytesSent = 0;
      int candidateBytesReceived = 0;

      for (final s in stats) {
        final v = s.values;
        if (s.type == 'outbound-rtp') {
          totalBytesSent += (v['bytesSent'] as num?)?.toInt() ?? 0;
        }
        if (s.type == 'inbound-rtp') {
          totalBytesReceived += (v['bytesReceived'] as num?)?.toInt() ?? 0;
        }
        if (s.type == 'candidate-pair' && (v['state'] == 'succeeded')) {
          candidateBytesSent = (v['bytesSent'] as num?)?.toInt() ?? 0;
          candidateBytesReceived = (v['bytesReceived'] as num?)?.toInt() ?? 0;
        }
      }

      _bytesSent = totalBytesSent > 0 ? totalBytesSent : candidateBytesSent;
      _bytesReceived = totalBytesReceived > 0 ? totalBytesReceived : candidateBytesReceived;

      _log('B', 'Stats: 发送=$_bytesSent bytes, 接收=$_bytesReceived bytes'
          ' (rtp发送=$totalBytesSent, rtp接收=$totalBytesReceived,'
          ' pair发送=$candidateBytesSent, pair接收=$candidateBytesReceived)');
    } catch (e) {
      _log('B', 'Stats 获取失败: $e');
    }
  }

  // ---- 事件回调 ----

  void _onIceCandidate(RTCIceCandidate candidate) {
    _log('B', 'ICE candidate: ${candidate.candidate?.substring(0, (candidate.candidate?.length ?? 0).clamp(0, 80))}...');
    pendingCandidates.add(candidate);
  }

  void _onIceGatheringState(RTCIceGatheringState state) {
    _log('B', 'ICE gathering: $state');
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      _iceGatherDone?.complete();
    }
  }

  void _onIceConnectionState(RTCIceConnectionState state) {
    _log('B', 'ICE connection: $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected && !_connected) {
      _connected = true;
      _startStatsTimer();
      _connectDone?.complete();
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    _log('B', 'Connection: $state');
  }

  void _onSignalingState(RTCSignalingState state) {
    _log('B', 'Signaling: $state');
  }

  void _onDataChannel(RTCDataChannel channel) {
    _log('B', '收到 DataChannel: id=${channel.id} label=${channel.label}');
    _dc = channel;
    _dc!.onMessage = _onDcMessage;
    _dc!.onDataChannelState = _onDcState;
  }

  void _onDcState(RTCDataChannelState state) {
    _log('B', 'DataChannel 状态: $state');
  }

  void _onDcMessage(RTCDataChannelMessage message) {
    if (message.isBinary) {
      _log('B', 'DC 收到二进制: ${message.binary.length} bytes');
      dcBinaryReceived.add(message.binary);
    } else {
      _log('B', 'DC 收到字符串: "${message.text}"');
      dcMessagesReceived.add(message.text);
    }
  }

  void _onTrack(RTCTrackEvent event) {
    _log('B', 'onTrack: trackId=${event.track.id} kind=${event.track.kind}'
        ' streams=${event.streams.map((s) => s.id).toList()}');
    for (final s in event.streams) {
      if (!_remoteStreams.any((rs) => rs.id == s.id)) {
        _remoteStreams.add(s);
      }
    }
  }

  void _onAddStream(MediaStream stream) {
    _log('B', 'onAddStream: streamId=${stream.id}');
    if (!_remoteStreams.any((s) => s.id == stream.id)) {
      _remoteStreams.add(stream);
    }
  }

  void _onRemoveStream(MediaStream stream) {
    _log('B', 'onRemoveStream: streamId=${stream.id}');
    _remoteStreams.removeWhere((s) => s.id == stream.id);
  }

  // ---- 释放资源 ----

  Future<void> stop() async {
    _log('B', '=== 开始释放接收端资源 ===');
    _statsTimer?.cancel();
    _statsTimer = null;

    if (_dc != null) {
      try { await _dc!.close(); } catch (_) {}
      _dc = null;
      _log('B', 'DataChannel 已关闭');
    }

    if (_pc != null) {
      try { await _pc!.close(); } catch (_) {}
      try { await _pc!.dispose(); } catch (_) {}
      _pc = null;
      _log('B', 'PeerConnection 已释放');
    }

    if (_sysAudioPc != null) {
      try { await _sysAudioPc!.close(); } catch (_) {}
      try { await _sysAudioPc!.dispose(); } catch (_) {}
      _sysAudioPc = null;
      _log('B', '系统音频 PC 已释放');
    }

    _remoteStreams.clear();
    pendingCandidates.clear();
    sysAudioPendingCandidates.clear();
    _connected = false;
    _log('B', '=== 接收端资源释放完成 ===');
  }
}