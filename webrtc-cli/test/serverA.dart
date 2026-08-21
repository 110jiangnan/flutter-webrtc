import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:webrtc_cli/webrtc_cli.dart';

final _log = (String tag, String msg) => print('[${DateTime.now().toIso8601String()}] [$tag] $msg');

/// 发送端/被控端: 屏幕共享 + 麦克风 + 摄像头 + DataChannel。
class ServerA {
  RTCPeerConnection? _pc;
  MediaStream? _screenStream;
  MediaStream? _micStream;
  MediaStream? _camStream;
  MediaStream? _sysAudioStream;
  RTCDataChannel? _dc;

  Timer? _statsTimer;
  int _bytesSent = 0;
  int _bytesReceived = 0;

  // ICE candidates 待传给 ClientB
  final List<RTCIceCandidate> pendingCandidates = [];
  Completer<void>? _iceGatherDone;

  // DataChannel 消息日志
  final List<String> dcMessagesReceived = [];
  final List<Uint8List> dcBinaryReceived = [];

  // 连接状态
  bool _connected = false;
  Completer<void>? _connectDone;

  Future<void> start() async {
    _log('A', '=== 开始初始化发送端 ===');

    // 1. 创建 PeerConnection
    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _log('A', 'PeerConnection 已创建');

    // 绑定事件回调
    _pc!.onIceCandidate = _onIceCandidate;
    _pc!.onIceGatheringState = _onIceGatheringState;
    _pc!.onIceConnectionState = _onIceConnectionState;
    _pc!.onConnectionState = _onConnectionState;
    _pc!.onSignalingState = _onSignalingState;
    _pc!.onDataChannel = _onRemoteDataChannel;
    _pc!.onTrack = _onTrack;
    _pc!.onAddStream = _onAddStream;
    _pc!.onRemoveStream = _onRemoveStream;

    // 2. 采集屏幕
    try {
      _screenStream = await getDisplayMedia({'video': true});
      _log('A', '屏幕采集成功 streamId=${_screenStream!.id}');
      for (final t in _screenStream!.getVideoTracks()) {
        _log('A', '  屏幕视频轨: ${t.id} ${t.kind}');
        _pc!.addTrack(t, _screenStream!);
      }
    } catch (e) {
      _log('A', '屏幕采集失败(可能无显示器): $e');
    }

    // 3. 采集麦克风
    try {
      _micStream = await getUserMedia({'audio': true, 'video': false});
      _log('A', '麦克风采集成功 streamId=${_micStream!.id}');
      for (final t in _micStream!.getAudioTracks()) {
        _log('A', '  麦克风轨: ${t.id} ${t.kind}');
        _pc!.addTrack(t, _micStream!);
      }
    } catch (e) {
      _log('A', '麦克风采集失败: $e');
    }

    // 4. 采集摄像头
    try {
      _camStream = await getUserMedia({'audio': false, 'video': true});
      _log('A', '摄像头采集成功 streamId=${_camStream!.id}');
      for (final t in _camStream!.getVideoTracks()) {
        _log('A', '  摄像头视频轨: ${t.id} ${t.kind}');
        _pc!.addTrack(t, _camStream!);
      }
    } catch (e) {
      _log('A', '摄像头采集失败: $e');
    }

    // 5. 系统音频(被控端)
    try {
      _sysAudioStream = await SysAudioManager.getSysAudioMedia();
      _log('A', '系统音频采集成功 streamId=${_sysAudioStream!.id}');
      for (final t in _sysAudioStream!.getAudioTracks()) {
        _log('A', '  系统音频轨: ${t.id} ${t.kind}');
        _pc!.addTrack(t, _sysAudioStream!);
      }
    } catch (e) {
      _log('A', '系统音频采集失败: $e');
    }

    // 6. 创建 DataChannel
    _dc = await _pc!.createDataChannel('test-dc', RTCDataChannelInit());
    _log('A', 'DataChannel 已创建 id=${_dc!.id} label=${_dc!.label}');
    _dc!.onDataChannelState = _onDcState;
    _dc!.onMessage = _onDcMessage;

    _log('A', '=== 发送端初始化完成 ===');
  }

  /// 创建 Offer
  Future<RTCSessionDescription> createOffer() async {
    _log('A', '创建 Offer...');
    final offer = await _pc!.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
    _log('A', 'Offer 已创建 type=${offer.type}');
    return offer;
  }

  Future<void> setLocalDescription(RTCSessionDescription desc) async {
    _iceGatherDone = Completer<void>();
    _connectDone = Completer<void>();
    await _pc!.setLocalDescription(desc);
    _log('A', 'LocalDescription 已设置 type=${desc.type}');
  }

  Future<void> setRemoteDescription(RTCSessionDescription desc) async {
    await _pc!.setRemoteDescription(desc);
    _log('A', 'RemoteDescription 已设置 type=${desc.type}');
  }

  Future<void> addRemoteCandidate(RTCIceCandidate c) async {
    await _pc!.addCandidate(c);
    _log('A', '已添加远端 ICE candidate: ${c.candidate?.substring(0, (c.candidate?.length ?? 0).clamp(0, 60))}...');
  }

  /// 等待 ICE gathering 完成
  Future<void> waitIceGathering() => _iceGatherDone?.future ?? Future.value();

  /// 等待连接建立
  Future<void> waitConnected() => _connectDone?.future ?? Future.value();

  // ---- DataChannel 发送 ----

  Future<void> sendString(String text) async {
    if (_dc == null) return;
    _dc!.send(RTCDataChannelMessage(text));
    _log('A', 'DC 发送字符串: "$text"');
  }

  Future<void> sendBinary(Uint8List data) async {
    if (_dc == null) return;
    _dc!.send(RTCDataChannelMessage.fromBinary(data));
    _log('A', 'DC 发送二进制: ${data.length} bytes');
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

      _log('A', 'Stats: 发送=$_bytesSent bytes, 接收=$_bytesReceived bytes'
          ' (rtp发送=$totalBytesSent, rtp接收=$totalBytesReceived,'
          ' pair发送=$candidateBytesSent, pair接收=$candidateBytesReceived)');
    } catch (e) {
      _log('A', 'Stats 获取失败: $e');
    }
  }

  // ---- 事件回调 ----

  void _onIceCandidate(RTCIceCandidate candidate) {
    _log('A', 'ICE candidate: ${candidate.candidate?.substring(0, (candidate.candidate?.length ?? 0).clamp(0, 80))}...');
    pendingCandidates.add(candidate);
  }

  void _onIceGatheringState(RTCIceGatheringState state) {
    _log('A', 'ICE gathering: $state');
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      _iceGatherDone?.complete();
    }
  }

  void _onIceConnectionState(RTCIceConnectionState state) {
    _log('A', 'ICE connection: $state');
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected && !_connected) {
      _connected = true;
      _startStatsTimer();
      _connectDone?.complete();
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    _log('A', 'Connection: $state');
  }

  void _onSignalingState(RTCSignalingState state) {
    _log('A', 'Signaling: $state');
  }

  void _onRemoteDataChannel(RTCDataChannel channel) {
    _log('A', '收到远端 DataChannel: id=${channel.id} label=${channel.label}');
    channel.onMessage = _onDcMessage;
    channel.onDataChannelState = _onDcState;
  }

  void _onDcState(RTCDataChannelState state) {
    _log('A', 'DataChannel 状态: $state');
  }

  void _onDcMessage(RTCDataChannelMessage message) {
    if (message.isBinary) {
      _log('A', 'DC 收到二进制: ${message.binary.length} bytes');
      dcBinaryReceived.add(message.binary);
    } else {
      _log('A', 'DC 收到字符串: "${message.text}"');
      dcMessagesReceived.add(message.text);
    }
  }

  void _onTrack(RTCTrackEvent event) {
    _log('A', 'onTrack: trackId=${event.track.id} kind=${event.track.kind}');
  }

  void _onAddStream(MediaStream stream) {
    _log('A', 'onAddStream: streamId=${stream.id}');
  }

  void _onRemoveStream(MediaStream stream) {
    _log('A', 'onRemoveStream: streamId=${stream.id}');
  }

  // ---- 释放资源 ----

  Future<void> stop() async {
    _log('A', '=== 开始释放发送端资源 ===');
    _statsTimer?.cancel();
    _statsTimer = null;

    if (_dc != null) {
      try { await _dc!.close(); } catch (_) {}
      _dc = null;
      _log('A', 'DataChannel 已关闭');
    }

    if (_pc != null) {
      try { await _pc!.close(); } catch (_) {}
      try { await _pc!.dispose(); } catch (_) {}
      _pc = null;
      _log('A', 'PeerConnection 已释放');
    }

    if (_screenStream != null) {
      try { await _screenStream!.dispose(); } catch (_) {}
      _screenStream = null;
      _log('A', '屏幕流已释放');
    }
    if (_micStream != null) {
      try { await _micStream!.dispose(); } catch (_) {}
      _micStream = null;
      _log('A', '麦克风流已释放');
    }
    if (_camStream != null) {
      try { await _camStream!.dispose(); } catch (_) {}
      _camStream = null;
      _log('A', '摄像头流已释放');
    }
    if (_sysAudioStream != null) {
      try {
        await SysAudioManager.releaseSysAudioMedia(_sysAudioStream!.id);
      } catch (_) {}
      _sysAudioStream = null;
      _log('A', '系统音频流已释放');
    }

    pendingCandidates.clear();
    _connected = false;
    _log('A', '=== 发送端资源释放完成 ===');
  }
}