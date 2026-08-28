// 麦克风回环测试: A 采集本机麦克风 → 发给 B, B 接收并播放(扬声器输出)。
//   - 复现 controller-mic 的传输方向: 发送方采集 → 接收方播放
//   - A: getUserMedia(audio) 采集麦克风, addTrack 到 PC
//   - B: 接收远端音频轨, onTrack 触发; 底层 libwebrtc ADM 自动 playout
//   - 全程打印 stats 音频 RTP 流量(audioLevel / bytesSent / bytesReceived)
//   - 你对着麦克风说话, 听 B 端扬声器是否有声音
// 运行:
//   cd E:\game\MyDesk\MyDesk\flutter-webrtc\webrtc-cli
//   E:/home/flutter/flutter_windows_3.47.0-0.1.pre-beta/flutter/bin/cache/dart-sdk/bin/dart.exe test/mic_loopback.dart
import 'dart:async';
import 'dart:io';

import 'package:webrtc_cli/webrtc_cli.dart';

final _log = (String tag, String msg) =>
    print('[${DateTime.now().toIso8601String()}] [$tag] $msg');

// ---- 可调参数 ----
final int kRunSeconds =
    int.tryParse(Platform.environment['MIC_LOOPBACK_SECONDS'] ?? '') ?? 60; // 建连后观察时长(默认60s, 可用环境变量覆盖)
const Duration kReportEvery = Duration(seconds: 3);

class Traffic {
  int rtpSent = 0; // stats: outbound-rtp 字节
  int rtpReceived = 0; // stats: inbound-rtp 字节
  int audioPacketsSent = 0;
  int audioPacketsReceived = 0;
}

/// A: 麦克风采集发送端
class MicSender {
  RTCPeerConnection? _pc;
  MediaStream? _micStream;
  final pendingCandidates = <RTCIceCandidate>[];
  Completer<void>? _iceGatherDone;
  bool _connected = false;
  Completer<void>? _connectDone;

  Future<void> start() async {
    _log('A', '=== 初始化麦克风发送端 ===');
    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _pc!.onIceCandidate = (c) {
      _log('A', 'ICE candidate: ${c.candidate?.substring(0, (c.candidate?.length ?? 0).clamp(0, 70))}');
      pendingCandidates.add(c);
    };
    _pc!.onIceGatheringState = (s) {
      _log('A', 'ICE gathering: $s');
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        _iceGatherDone?.complete();
      }
    };
    _pc!.onConnectionState = (s) {
      _log('A', 'Connection: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectDone?.complete();
      }
    };
    _pc!.onTrack = (e) =>
        _log('A', 'onTrack(回环): ${e.track.kind} ${e.track.id} streams=${e.streams.length}');

    // 采集麦克风
    try {
      _micStream = await getUserMedia({'audio': true, 'video': false});
      _log('A', '麦克风采集成功 streamId=${_micStream!.id}');
      for (final t in _micStream!.getAudioTracks()) {
        _log('A', '  麦克风轨: id=${t.id} kind=${t.kind} enabled=${t.enabled}');
        await _pc!.addTrack(t, _micStream!);
      }
    } catch (e) {
      _log('A', '!!! 麦克风采集失败: $e');
      rethrow;
    }
    _log('A', '=== 发送端初始化完成 ===');
  }

  Future<RTCSessionDescription> createOffer() async {
    final offer = await _pc!.createOffer({'offerToReceiveAudio': true});
    _log('A', 'Offer 已创建 type=${offer.type}');
    return offer;
  }

  Future<void> setLocalDescription(RTCSessionDescription d) async {
    _iceGatherDone = Completer<void>();
    _connectDone = Completer<void>();
    await _pc!.setLocalDescription(d);
  }

  Future<void> setRemoteDescription(RTCSessionDescription d) async {
    await _pc!.setRemoteDescription(d);
    _log('A', 'RemoteDescription 已设置');
  }

  Future<void> addRemoteCandidate(RTCIceCandidate c) => _pc!.addCandidate(c);
  Future<void> waitIceGathering() => _iceGatherDone?.future ?? Future.value();
  Future<void> waitConnected() => _connectDone?.future ?? Future.value();

  Future<void> stop() async {
    _log('A', '=== 释放发送端 ===');
    if (_micStream != null) {
      try {
        for (final t in _micStream!.getTracks()) {
          await t.stop();
        }
      } catch (_) {}
      try {
        await _micStream!.dispose();
      } catch (_) {}
      _micStream = null;
    }
    if (_pc != null) {
      try { await _pc!.close(); } catch (_) {}
      try { await _pc!.dispose(); } catch (_) {}
      _pc = null;
    }
    pendingCandidates.clear();
    _log('A', '=== 发送端释放完成 ===');
  }
}

/// B: 麦克风接收播放端
class MicReceiver {
  RTCPeerConnection? _pc;
  final remoteStreams = <MediaStream>[];
  final pendingCandidates = <RTCIceCandidate>[];
  Completer<void>? _iceGatherDone;
  bool _connected = false;
  Completer<void>? _connectDone;
  final audioTracks = <MediaStreamTrack>[];

  /// 建 PC 前先选好播放设备(复现 MediaHelper.initAudioOutDevice 的时机):
  /// ADM 未初始化时 SetPlayoutDevice 才生效, 建 PC 后再选可能已无效。
  Future<void> _selectOutputBeforePc() async {
    try {
      final devices = await mediaDevices.enumerateDevices();
      final outputs = devices.where((d) => d.kind == 'audiooutput').toList();
      _log('B', '音频输出设备 ${outputs.length} 个:');
      for (final d in outputs) {
        _log('B', '  输出: label=${d.label} deviceId=${d.deviceId}');
      }
      if (outputs.isEmpty) {
        _log('B', '  !!! 无音频输出设备, 无法播放');
        return;
      }
      // 优先选含"扬声器"/realtek 的设备, 否则第一个
      MediaDeviceInfo? pick;
      for (final d in outputs) {
        if (d.label.contains('扬声器') || d.label.toLowerCase().contains('realtek')) {
          pick = d;
          break;
        }
      }
      pick ??= outputs.first;
      _log('B', '  选中播放设备: ${pick.label}');
      await mediaDevices.selectAudioOutput(AudioOutputOptions(deviceId: pick.deviceId));
      _log('B', '  selectAudioOutput 完成(建 PC 前)');
    } catch (e) {
      _log('B', '选播放设备异常: $e');
    }
  }

  /// onTrack 后拉满远端音轨音量(排除音量 0 无声)。
  Future<void> _setRemoteTrackVolume() async {
    for (final t in audioTracks) {
      try {
        await Helper.setVolume(1.0, t);
        _log('B', '  远端音轨 ${t.id} 音量已设为 1.0');
      } catch (e) {
        _log('B', '设音量异常: $e');
      }
    }
  }

  Future<void> start() async {
    _log('B', '=== 初始化麦克风接收端 ===');
    await _selectOutputBeforePc();
    _log('B', '--- 建 PC ---');
    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _pc!.onIceCandidate = (c) {
      _log('B', 'ICE candidate: ${c.candidate?.substring(0, (c.candidate?.length ?? 0).clamp(0, 70))}');
      pendingCandidates.add(c);
    };
    _pc!.onIceGatheringState = (s) {
      _log('B', 'ICE gathering: $s');
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        _iceGatherDone?.complete();
      }
    };
    _pc!.onConnectionState = (s) {
      _log('B', 'Connection: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectDone?.complete();
      }
    };
    _pc!.onTrack = (e) {
      _log('B', 'onTrack: kind=${e.track.kind} id=${e.track.id}'
          ' enabled=${e.track.enabled} streams=${e.streams.map((s) => s.id).toList()}');
      if (e.track.kind == 'audio') {
        audioTracks.add(e.track);
        _log('B', '  远端音频轨 ${e.track.id} 已记录, 播放交给底层 ADM playout');
        _setRemoteTrackVolume();
      }
      for (final s in e.streams) {
        if (!remoteStreams.any((rs) => rs.id == s.id)) remoteStreams.add(s);
      }
    };
    _log('B', '=== 接收端初始化完成 ===');
  }

  Future<void> setRemoteDescription(RTCSessionDescription d) async {
    _connectDone = Completer<void>();
    await _pc!.setRemoteDescription(d);
    _log('B', 'RemoteDescription 已设置');
  }

  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _pc!.createAnswer();
    _log('B', 'Answer 已创建 type=${answer.type}');
    return answer;
  }

  Future<void> setLocalDescription(RTCSessionDescription d) async {
    _iceGatherDone = Completer<void>();
    await _pc!.setLocalDescription(d);
  }

  Future<void> addRemoteCandidate(RTCIceCandidate c) => _pc!.addCandidate(c);
  Future<void> waitIceGathering() => _iceGatherDone?.future ?? Future.value();
  Future<void> waitConnected() => _connectDone?.future ?? Future.value();

  Future<void> stop() async {
    _log('B', '=== 释放接收端 ===');
    audioTracks.clear();
    remoteStreams.clear();
    if (_pc != null) {
      try { await _pc!.close(); } catch (_) {}
      try { await _pc!.dispose(); } catch (_) {}
      _pc = null;
    }
    pendingCandidates.clear();
    _log('B', '=== 接收端释放完成 ===');
  }
}

/// 交换 SDP + ICE candidates(A offer → B answer)
Future<void> connectPeers(MicSender a, MicReceiver b) async {
  _log('MAIN', '--- 开始 SDP/ICE 交换 ---');
  final offer = await a.createOffer();
  await a.setLocalDescription(offer);
  await b.setRemoteDescription(offer);

  _log('MAIN', '等待 A 的 ICE gathering...');
  await a.waitIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 500));
  _log('MAIN', 'A 共 ${a.pendingCandidates.length} 个 candidates');
  for (final c in a.pendingCandidates) {
    await b.addRemoteCandidate(c);
  }

  final answer = await b.createAnswer();
  await b.setLocalDescription(answer);
  await a.setRemoteDescription(answer);

  _log('MAIN', '等待 B 的 ICE gathering...');
  await b.waitIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 500));
  _log('MAIN', 'B 共 ${b.pendingCandidates.length} 个 candidates');
  for (final c in b.pendingCandidates) {
    await a.addRemoteCandidate(c);
  }

  _log('MAIN', '--- SDP/ICE 交换完成, 等待连接 ---');
  try {
    await Future.any([
      Future.wait([a.waitConnected(), b.waitConnected()]),
      Future.delayed(const Duration(seconds: 20)),
    ]);
  } catch (_) {}
  _log('MAIN', '连接阶段结束');
}

Future<void> printStats(RTCPeerConnection? pc, String who, Traffic t) async {
  if (pc == null) return;
  try {
    final stats = await pc.getStats();
    int sent = 0, recv = 0, aPktSent = 0, aPktRecv = 0;
    for (final s in stats) {
      final v = s.values;
      if (s.type == 'outbound-rtp') {
        sent += (v['bytesSent'] as num?)?.toInt() ?? 0;
        if (v['kind'] == 'audio' || v['mediaType'] == 'audio') {
          aPktSent += (v['packetsSent'] as num?)?.toInt() ?? 0;
        }
      } else if (s.type == 'inbound-rtp') {
        recv += (v['bytesReceived'] as num?)?.toInt() ?? 0;
        if (v['kind'] == 'audio' || v['mediaType'] == 'audio') {
          aPktRecv += (v['packetsReceived'] as num?)?.toInt() ?? 0;
        }
      }
    }
    t.rtpSent = sent;
    t.rtpReceived = recv;
    t.audioPacketsSent = aPktSent;
    t.audioPacketsReceived = aPktRecv;
    _log(who, 'Stats: RTP发送=$sent bytes, RTP接收=$recv bytes'
        ' (音频包: 发$aPktSent/收$aPktRecv)');
  } catch (e) {
    _log(who, 'Stats 失败: $e');
  }
}

Future<void> main() async {
  _log('MAIN', '=== 麦克风回环测试启动 ===');
  _log('MAIN', 'A 采本机麦克风 → B 扬声器播放');
  _log('MAIN', '请准备: 对着麦克风说话, 听扬声器是否有声音');

  final a = MicSender();
  final b = MicReceiver();

  try {
    _log('MAIN', '初始化 A...');
    await a.start();
    _log('MAIN', '初始化 B...');
    await b.start();

    await connectPeers(a, b);

    _log('MAIN', '连接建立(或超时), 开始 ${kRunSeconds}s 观察...');
    _log('MAIN', '>>> 现在请对着麦克风说话, 听 B 端扬声器 <<<');

    final t = Traffic();
    final deadline = DateTime.now().add(Duration(seconds: kRunSeconds));
    while (DateTime.now().isBefore(deadline)) {
      await printStats(a._pc, 'A', t);
      await printStats(b._pc, 'B', t);
      await Future.delayed(kReportEvery);
    }

    _log('MAIN', '测试结束, 最终统计:');
    _log('MAIN', '  A 收到音频轨数=${a._micStream?.getAudioTracks().length}');
    _log('MAIN', '  B 收到远端音频轨数=${b.audioTracks.length}');
    _log('MAIN', '  A RTP发送=${t.rtpSent} bytes (音频包 ${t.audioPacketsSent})');
    _log('MAIN', '  B RTP接收=${t.rtpReceived} bytes (音频包 ${t.audioPacketsReceived})');
    if (t.audioPacketsReceived > 0) {
      _log('MAIN', '  ✓ B 收到真实音频 RTP 包, 说明传输链路通');
    } else {
      _log('MAIN', '  ✗ B 未收到音频 RTP 包, 传输链路有问题');
    }
  } catch (e, st) {
    _log('MAIN', '测试异常: $e');
    _log('MAIN', '$st');
  } finally {
    _log('MAIN', '释放资源...');
    await a.stop();
    await b.stop();
    try {
      await dispose();
      _log('MAIN', '全局 factory 已释放');
    } catch (_) {}
  }
}
