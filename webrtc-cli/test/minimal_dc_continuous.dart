// 最小复现: 用 testMain 已知能通的 ServerA/ClientB, 只把 DataChannel 换成
// 持续大流量二进制发送(带 bufferedAmount 限流)。判断问题出在"脚本设置"还是
// "连续大流量发送路径本身"。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:webrtc_cli/webrtc_cli.dart';
import 'serverA.dart';
import 'clientB.dart';

final _log = (String msg) =>
    print('[${DateTime.now().toIso8601String()}] [MIN] $msg');

Future<void> main() async {
  _log('=== 最小复现: ServerA/ClientB + 持续二进制发送 ===');

  final a = ServerA();
  final b = ClientB();
  await a.start();
  await b.start();

  // ---- 连接(镜像 testMain.connectPeers) ----
  final offer = await a.createOffer();
  await a.setLocalDescription(offer);
  await b.setRemoteDescription(offer);
  await a.waitIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));
  for (final c in a.pendingCandidates) {
    await b.addRemoteCandidate(c);
  }
  final answer = await b.createAnswer();
  await b.setLocalDescription(answer);
  await a.setRemoteDescription(answer);
  await b.waitIceGathering().timeout(const Duration(seconds: 15), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));
  for (final c in b.pendingCandidates) {
    await a.addRemoteCandidate(c);
  }
  await Future.any([
    Future.wait([a.waitConnected(), b.waitConnected()]),
    Future.delayed(const Duration(seconds: 20)),
  ]);
  _log('连接阶段结束');

  // ---- 先发几条小消息验证通道(镜像 testMain) ----
  await a.sendString('hello from server A');
  await Future.delayed(const Duration(milliseconds: 800));
  _log('A 发小消息后, B 收到: ${b.dcMessagesReceived.length} 条,'
      ' 二进制 ${b.dcBinaryReceived.length} 条');

  // ---- 持续大流量二进制发送(15s, 固定节奏) ----
  _log('开始持续发送 15s...');
  final chunk = Uint8List(32 * 1024);
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  int sentTotal = 0;
  while (DateTime.now().isBefore(deadline)) {
    for (int i = 0; i < 20; i++) {
      a.sendBinary(chunk);
      sentTotal += chunk.length;
    }
    await Future.delayed(const Duration(milliseconds: 2));
  }
  _log('持续发送结束, A 共发送 ${(sentTotal / 1024 / 1024).toStringAsFixed(1)}MB,'
      ' B 收到二进制: ${b.dcBinaryReceived.length} 条'
      ' B 收到字符串: ${b.dcMessagesReceived.length} 条');

  await a.stop();
  await b.stop();
  try { await dispose(); } catch (_) {}
  _log('=== 最小复现完成 ===');
  exit(0);
}
