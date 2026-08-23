import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:webrtc_cli/webrtc_cli.dart';

import 'clientB.dart';
import 'serverA.dart';

final _log = (String msg) => print('[${DateTime.now().toIso8601String()}] [MAIN] $msg');

/// 连接 ServerA 和 ClientB: 交换 SDP + ICE candidates。
Future<void> connectPeers(ServerA a, ClientB b) async {
  _log('--- 开始 SDP/ICE 交换 ---');

  // 1. A 创建 offer → A setLocal → B setRemote
  final offer = await a.createOffer();
  await a.setLocalDescription(offer);
  await b.setRemoteDescription(offer);

  // 2. 等待 A 的 ICE gathering 完成, 交换 A 的 candidates 给 B
  _log('等待 A 的 ICE gathering 完成...');
  await a.waitIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {
    _log('A ICE gathering 超时, 继续...');
  });
  await Future.delayed(const Duration(milliseconds: 500));
  _log('A 共收集 ${a.pendingCandidates.length} 个 ICE candidates');
  for (final c in a.pendingCandidates) {
    await b.addRemoteCandidate(c);
  }

  // 3. B 创建 answer → B setLocal → A setRemote
  final answer = await b.createAnswer();
  await b.setLocalDescription(answer);
  await a.setRemoteDescription(answer);

  // 4. 等待 B 的 ICE gathering 完成, 交换 B 的 candidates 给 A
  _log('等待 B 的 ICE gathering 完成...');
  await b.waitIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {
    _log('B ICE gathering 超时, 继续...');
  });
  await Future.delayed(const Duration(milliseconds: 500));
  _log('B 共收集 ${b.pendingCandidates.length} 个 ICE candidates');
  for (final c in b.pendingCandidates) {
    await a.addRemoteCandidate(c);
  }

  _log('--- SDP/ICE 交换完成, 等待连接建立 ---');

  // 5. 等待连接建立
  try {
    await Future.any([
      Future.wait([a.waitConnected(), b.waitConnected()]),
      Future.delayed(const Duration(seconds: 20)),
    ]);
    _log('连接建立阶段结束');
  } catch (_) {
    _log('连接等待超时');
  }
}

/// 连接 ServerA 和 ClientB 的系统音频专用 PC(isSysAudio)。
/// mac 上系统音频必须走独立 PC(emptyPcFactory), 不能与麦克风混到普通 PC。
Future<void> connectSysAudioPeers(ServerA a, ClientB b) async {
  if (!a.hasSysAudioPc || !b.hasSysAudioPc) {
    _log('--- 系统音频 PC 未创建, 跳过 ---');
    return;
  }
  _log('--- 开始系统音频 SDP/ICE 交换 ---');

  // A 系统音频 offer → A setLocal → B setRemote
  final offer = await a.createSysAudioOffer();
  await a.setSysAudioLocalDescription(offer);
  await b.setSysAudioRemoteDescription(offer);

  // 交换 A 的 candidates
  await a.waitSysAudioIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));
  _log('A 系统音频收集 ${a.sysAudioPendingCandidates.length} 个 candidates');
  for (final c in a.sysAudioPendingCandidates) {
    await b.addSysAudioRemoteCandidate(c);
  }

  // B answer → B setLocal → A setRemote
  final answer = await b.createSysAudioAnswer();
  await b.setSysAudioLocalDescription(answer);
  await a.setSysAudioRemoteDescription(answer);

  // 交换 B 的 candidates
  await b.waitSysAudioIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));
  _log('B 系统音频收集 ${b.sysAudioPendingCandidates.length} 个 candidates');
  for (final c in b.sysAudioPendingCandidates) {
    await a.addSysAudioRemoteCandidate(c);
  }

  // 等待系统音频连接建立
  try {
    await Future.any([
      Future.wait([a.waitSysAudioConnected(), b.waitSysAudioConnected()]),
      Future.delayed(const Duration(seconds: 20)),
    ]);
    _log('系统音频连接建立阶段结束');
  } catch (_) {
    _log('系统音频连接等待超时');
  }
}

/// 测试 DataChannel 双向收发: 字符串 + 二进制。
Future<void> testDataChannel(ServerA a, ClientB b) async {
  _log('--- 开始 DataChannel 测试 ---');

  await Future.delayed(const Duration(seconds: 1));

  // A 发送字符串给 B
  _log('A → B 字符串...');
  await a.sendString('hello from server A');
  await Future.delayed(const Duration(milliseconds: 500));

  // A 发送二进制给 B
  _log('A → B 二进制...');
  await a.sendBinary(Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC]));
  await Future.delayed(const Duration(milliseconds: 500));

  // B 回复字符串给 A
  _log('B → A 字符串...');
  await b.sendDcString('hello from client B');
  await Future.delayed(const Duration(milliseconds: 500));

  // B 回复二进制给 A
  _log('B → A 二进制...');
  await b.sendDcBinary(Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]));
  await Future.delayed(const Duration(milliseconds: 500));

  // 再发几轮
  for (int i = 0; i < 3; i++) {
    await a.sendString('ping $i from A');
    await Future.delayed(const Duration(milliseconds: 200));
    await b.sendDcString('pong $i from B');
    await Future.delayed(const Duration(milliseconds: 200));
  }

  _log('--- DataChannel 测试完成 ---');
  _log('A DC 收到字符串: ${a.dcMessagesReceived.length} 条');
  _log('A DC 收到二进制: ${a.dcBinaryReceived.length} 条');
  _log('B DC 收到字符串: ${b.dcMessagesReceived.length} 条');
  _log('B DC 收到二进制: ${b.dcBinaryReceived.length} 条');
}

/// 打印内存使用情况(Windows tasklist)。
void _printMemory() {
  try {
    final result = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq dart.exe', '/FO', 'CSV', '/NH']);
    if (result.exitCode == 0) {
      for (final line in (result.stdout as String).split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final parts = trimmed.split(',');
        if (parts.length >= 5) {
          final mem = parts[4].replaceAll('"', '').replaceAll(' K', '');
          _log('dart.exe 进程内存: ${mem}KB (~${(int.parse(mem) / 1024).toStringAsFixed(1)}MB)');
        }
      }
    }
  } catch (_) {}
}

/// 单轮测试。
Future<void> runRound(int round) async {
  _log('============================================================');
  _log('              第 $round 轮测试开始');
  _log('============================================================');
  _printMemory();

  final a = ServerA();
  final b = ClientB();

  try {
    // 1. 初始化
    _log('初始化 A...');
    await a.start();
    _log('初始化 B...');
    await b.start();
    _printMemory();

    // 2. 连接
    await connectPeers(a, b);
    // 系统音频独立 PC 连接
    await connectSysAudioPeers(a, b);
    _printMemory();

    // 3. DataChannel 测试
    await testDataChannel(a, b);

    // 4. 运行 30 秒采集 stats
    _log('连接建立, 运行 30 秒采集 stats...');
    await Future.delayed(const Duration(seconds: 30));
    _printMemory();

    _log('第 $round 轮测试完成');
  } catch (e, stack) {
    _log('第 $round 轮测试异常: $e');
    _log('$stack');
  } finally {
    // 5. 释放资源
    _log('释放 A 的资源...');
    await a.stop();
    _log('释放 B 的资源...');
    await b.stop();
    _printMemory();
  }
}

Future<void> main() async {
  _log('webrtc-cli 综合测试启动');
  _log('测试轮次: 3 轮, 每轮间隔 60 秒');
  _printMemory();

  for (int round = 1; round <= 3; round++) {
    await runRound(round);

    if (round < 3) {
      _log('============================================================');
      _log('等待 60 秒观察资源释放情况...');
      _log('============================================================');

      // 每 10 秒打印一次内存
      for (int i = 1; i <= 6; i++) {
        await Future.delayed(const Duration(seconds: 10));
        _log('等待中 (${i * 10}s / 60s)...');
        _printMemory();
      }
    }
  }

  _log('============================================================');
  _log('              全部 3 轮测试完成');
  _log('============================================================');
  _printMemory();

  // 释放全局 factory
  try {
    await dispose();
    _log('全局 factory 已释放');
  } catch (_) {}
}