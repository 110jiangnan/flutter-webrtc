// 压力测试: 系统音频采集(不崩 + 有流量) + DataChannel 持续大流量传输
//   - A: 采集系统音频(SysAudioManager) + 创建 DataChannel → 建连
//   - 连接后 DataChannel 持续发送大流量(目标 ~10MB/s), 用 bufferedAmount 限流:
//     超过 high watermark 暂停, 降到 low watermark 再继续发
//   - 全程(默认 90s)不中断传输, 每 5s 打印 A/B 吞吐 + stats 里的音频 RTP 流量
//   - 双看门狗保证必停: ①deadline 时间 ②发送字节上限 kMaxSentBytes
//   - 结束时干净释放, 确认不崩、无内存泄漏(打内存)
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:webrtc_cli/webrtc_cli.dart';

final _log = (String tag, String msg) =>
    print('[${DateTime.now().toIso8601String()}] [$tag] $msg');

// ---- 可调参数 ----
final int kRunSeconds =
    int.tryParse(Platform.environment['STRESS_SECONDS'] ?? '') ?? 90; // 持续传输时长(默认90s, 可用环境变量改)
const int kChunkSize = 32 * 1024; // 单帧二进制大小(32KB, 低于 SCTP 默认 64KB 上限)
const int kHighWater = 16 * 1024 * 1024; // bufferedAmount 上限(16MB), 超过暂停
const int kLowWater = 4 * 1024 * 1024; // 降到 4MB 再继续发
const int kMaxSentBytes = 3 * 1024 * 1024 * 1024; // 看门狗: 发送上限 3GB
const Duration kReportEvery = Duration(seconds: 5);

// ---- 跨 async 共享的状态 ----
bool _done = false;
DateTime? _deadline;

class Traffic {
  int dcSent = 0; // A: DC 发送字节(应用层)
  int dcReceived = 0; // B: DC 收到字节(应用层)
  int rtpSent = 0; // stats: outbound-rtp 字节(含系统音频)
  int rtpReceived = 0; // stats: inbound-rtp 字节
}

class ConnState {
  final a = Completer<bool>();
  final b = Completer<bool>();
}

String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1) + 'MB';

/// DataChannel 持续发送循环。
/// 关键: 循环内必须 `await Future.delayed()` 让出事件循环——接收端消息事件经
/// ReceivePort(宏任务)投递, 若只 await 已完成的 Future(微任务)会饿死事件循环,
/// 表现为 B 永远收不到(A 紧循环发得飞起但零交付)。bufferedAmount 限流照用。
Future<void> sendLoop(RTCDataChannel dc, Traffic t) async {
  final chunk = Uint8List(kChunkSize);
  int lastSent = 0;
  var lastT = DateTime.now();
  while (!_done &&
      (_deadline == null || DateTime.now().isBefore(_deadline!)) &&
      t.dcSent < kMaxSentBytes) {
    final buffered = await dc.getBufferedAmount() ?? 0;
    if (buffered < kHighWater) {
      // 每批发 8 帧后 yield, 既保吞吐又让接收端事件能被处理
      for (int i = 0; i < 8; i++) {
        dc.send(RTCDataChannelMessage.fromBinary(chunk));
        t.dcSent += chunk.length;
      }
      // 10ms: mac 上 SCTP 发送快, 1ms 让出不够, B 的 ReceivePort 会被饿死
      await Future.delayed(const Duration(milliseconds: 10));
    } else {
      // 缓冲堆积过高, 暂停等排空
      await Future.delayed(const Duration(milliseconds: 10));
    }
    // 每 5s 报告一次吞吐
    if (DateTime.now().difference(lastT) >= kReportEvery) {
      final dt = DateTime.now().difference(lastT).inMilliseconds / 1000.0;
      final mbps = (t.dcSent - lastSent) / 1024 / 1024 / dt;
      _log('A', 'DC 发送: 累计=${_mb(t.dcSent)} buffered=${_mb(buffered)}'
          ' 近${kReportEvery.inSeconds}s吞吐=${mbps.toStringAsFixed(1)}MB/s');
      lastSent = t.dcSent;
      lastT = DateTime.now();
    }
  }
  _log('A', '发送循环结束(看门狗或 _done), 共发送 ${_mb(t.dcSent)}');
}

/// stats 计时器: 读 RTP 流量(系统音频走 RTP)。
Timer? _startStatsTimer(RTCPeerConnection pc, String tag, Traffic t) {
  return Timer.periodic(kReportEvery, (_) async {
    try {
      final stats = await pc.getStats();
      int sent = 0, recv = 0, candSent = 0, candRecv = 0;
      for (final s in stats) {
        final v = s.values;
        if (s.type == 'outbound-rtp') {
          sent += (v['bytesSent'] as num?)?.toInt() ?? 0;
        }
        if (s.type == 'inbound-rtp') {
          recv += (v['bytesReceived'] as num?)?.toInt() ?? 0;
        }
        if (s.type == 'candidate-pair' && v['state'] == 'succeeded') {
          candSent = (v['bytesSent'] as num?)?.toInt() ?? 0;
          candRecv = (v['bytesReceived'] as num?)?.toInt() ?? 0;
        }
      }
      t.rtpSent = sent > 0 ? sent : candSent;
      t.rtpReceived = recv > 0 ? recv : candRecv;
      _log(tag, 'Stats: RTP发送=${_mb(t.rtpSent)} RTP接收=${_mb(t.rtpReceived)}'
          ' (pair发送=${_mb(candSent)} pair接收=${_mb(candRecv)})');
    } catch (e) {
      _log(tag, 'Stats 失败: $e');
    }
  });
}

void _printMemory() {
  try {
    final r = Process.runSync(
        'tasklist', ['/FI', 'IMAGENAME eq dart.exe', '/FO', 'CSV', '/NH']);
    if (r.exitCode == 0) {
      for (final line in (r.stdout as String).split('\n')) {
        final parts = line.trim().split(',');
        if (parts.length >= 5) {
          final mem = parts[4].replaceAll('"', '').replaceAll(' K', '');
          _log('MEM', 'dart.exe: ${(int.tryParse(mem) ?? 0) / 1024}MB');
        }
      }
    }
  } catch (_) {}
}

Future<void> main() async {
  _log('MAIN', '=== 系统音频 + DataChannel 压力测试启动 (${kRunSeconds}s) ===');
  _printMemory();

  final t = Traffic();
  final conn = ConnState();

  // ---- A: PC + 系统音频 + DataChannel ----
  _log('A', '初始化...');
  final a = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });
  MediaStream? sysAudio;
  try {
    sysAudio = await SysAudioManager.getSysAudioMedia();
    _log('A', '系统音频采集成功 streamId=${sysAudio!.id}');
    for (final tr in sysAudio!.getAudioTracks()) {
      await a.addTrack(tr, sysAudio!);
      _log('A', '  系统音频轨: ${tr.id} ${tr.kind}');
    }
  } catch (e) {
    _log('A', '系统音频采集失败: $e');
  }

  RTCDataChannel? dc;
  try {
    dc = await a.createDataChannel('stress', RTCDataChannelInit());
    _log('A', 'DataChannel 已创建 id=${dc!.id} label=${dc!.label}');
    dc!.onDataChannelState = (s) => _log('A', 'A DC 状态: $s');
    dc!.onMessage = (m) => _log('A', 'A 收到: ${m.isBinary ? "binary ${m.binary.length}B" : "text ${m.text}"}');
  } catch (e) {
    _log('A', 'DataChannel 创建失败: $e');
  }

  // ---- B: PC ----
  _log('B', '初始化...');
  final b = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });

  // ---- 注册全部回调(SDP 交换前!), 否则会错过 DataChannel 事件 ----
  final aCands = <RTCIceCandidate>[];
  final bCands = <RTCIceCandidate>[];
  Completer<void>? aGather, bGather;
  a.onIceCandidate = (c) => aCands.add(c);
  a.onIceGatheringState = (s) {
    if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) aGather?.complete();
  };
  a.onIceConnectionState = (s) {
    _log('A', 'ICE conn: $s');
    if (s == RTCIceConnectionState.RTCIceConnectionStateConnected &&
        !conn.a.isCompleted) {
      conn.a.complete(true);
    }
  };
  a.onConnectionState = (s) => _log('A', 'PC conn: $s');
  a.onSignalingState = (s) => _log('A', 'signaling: $s');
  b.onIceCandidate = (c) => bCands.add(c);
  b.onIceGatheringState = (s) {
    if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) bGather?.complete();
  };
  b.onIceConnectionState = (s) {
    _log('B', 'ICE conn: $s');
    if (s == RTCIceConnectionState.RTCIceConnectionStateConnected &&
        !conn.b.isCompleted) {
      conn.b.complete(true);
    }
  };
  b.onConnectionState = (s) => _log('B', 'PC conn: $s');
  b.onSignalingState = (s) => _log('B', 'signaling: $s');
  b.onTrack = (ev) => _log('B', 'onTrack: kind=${ev.track.kind} id=${ev.track.id}'
      ' streams=${ev.streams.map((s) => s.id).toList()}');
  b.onAddStream = (s) => _log('B', 'onAddStream: ${s.id}');

  // B: 收远端 DataChannel(必须在交换前注册)
  final dcOpen = Completer<void>();
  var bMsgCount = 0;
  var lastRecvLog = DateTime.now();
  b.onDataChannel = (ch) {
    _log('B', '收到 DataChannel id=${ch.id} label=${ch.label}');
    ch.onDataChannelState = (s) {
      _log('B', 'DC 状态: $s');
      if (s == RTCDataChannelState.RTCDataChannelOpen && !dcOpen.isCompleted) {
        dcOpen.complete();
      }
    };
    ch.onMessage = (m) {
      if (!m.isBinary) return;
      bMsgCount++;
      t.dcReceived += m.binary.length;
      if (DateTime.now().difference(lastRecvLog) >= kReportEvery) {
        _log('B', 'DC 收到: 累计=${_mb(t.dcReceived)} 消息数=$bMsgCount');
        lastRecvLog = DateTime.now();
      }
    };
  };

  // ---- SDP/ICE 交换 (A offer) ----
  _log('A', 'createOffer...');
  final offer = await a.createOffer(
      {'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
  _log('A', 'offer m-lines: ${offer.sdp!.split('\n').where((l) => l.startsWith('m=')).join(' | ')}');
  await a.setLocalDescription(offer);
  await b.setRemoteDescription(offer);

  aGather = Completer<void>();
  await aGather!.future.timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));
  _log('A', 'A 收集 ${aCands.length} 个 candidates, 发给 B...');
  for (final c in aCands) {
    await b.addCandidate(c);
  }

  final answer = await b.createAnswer();
  _log('B', 'answer m-lines: ${answer.sdp!.split('\n').where((l) => l.startsWith('m=')).join(' | ')}');
  await b.setLocalDescription(answer);
  await a.setRemoteDescription(answer);

  bGather = Completer<void>();
  await bGather!.future.timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));
  _log('B', 'B 收集 ${bCands.length} 个 candidates, 发给 A...');
  for (final c in bCands) {
    await a.addCandidate(c);
  }

  _log('MAIN', '等待 ICE connected...');
  final connected = await Future.any([
    conn.a.future,
    conn.b.future,
    Future.delayed(const Duration(seconds: 20), () => false),
  ]);
  if (!connected) {
    _log('MAIN', '连接失败, 直接清理退出');
  } else {
    _log('MAIN', 'ICE connected, 开始持续传输');
  }

  if (connected) {
    // ---- 等 DC 打开(或收到首条消息), 然后启动持续发送 + 双端 stats ----
    await dcOpen.future.timeout(const Duration(seconds: 15), onTimeout: () {});
    _log('MAIN', 'DC 就绪(open=${dcOpen.isCompleted}), 启动持续发送'
        ' (限流 high=${kHighWater >> 20}MB, 上限${kMaxSentBytes >> 30}GB)');
    final statsA = _startStatsTimer(a, 'A', t);
    final statsB = _startStatsTimer(b, 'B', t);

    _deadline = DateTime.now().add(Duration(seconds: kRunSeconds));
    final sendF = dc != null ? sendLoop(dc, t) : Future.value();
    _log('MAIN', '主循环等待到 deadline(${kRunSeconds}s)...');
    while (DateTime.now().isBefore(_deadline!)) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    _log('MAIN', 'deadline 到, 停发送(_done=true)');
    _done = true;
    await sendF;
    statsA?.cancel();
    statsB?.cancel();

    _log('MAIN', '--- 传输结束汇总 ---');
    _log('MAIN', 'A DC 共发送: ${_mb(t.dcSent)} (B 共接收: ${_mb(t.dcReceived)})');
    _log('MAIN', 'A RTP 发送(含系统音频): ${_mb(t.rtpSent)}');
    _log('MAIN', 'B RTP 接收: ${_mb(t.rtpReceived)}');
  }

  // ---- 干净释放 ----
  _log('MAIN', '清理资源...');
  if (sysAudio != null) {
    try {
      await SysAudioManager.releaseSysAudioMedia(sysAudio!.id);
      _log('A', '系统音频已释放');
    } catch (e) {
      _log('A', '系统音频释放失败: $e');
    }
  }
  if (dc != null) {
    try { await dc!.close(); } catch (_) {}
    _log('A', 'DataChannel 已关闭');
  }
  try { await a.close(); } catch (_) {}
  try { await a.dispose(); } catch (_) {}
  try { await b.close(); } catch (_) {}
  try { await b.dispose(); } catch (_) {}
  _log('MAIN', 'PC 已释放');

  _printMemory();
  try { await dispose(); } catch (_) {}
  _log('MAIN', '=== 压力测试完成, EXIT=0 ===');
  exit(0);
}
