// 复现: 纯 DataChannel 协商(无任何媒体轨)——与 mydesk 的 data PC 场景一致。
// A 建 PC + 只建 DC, 发 offer; B 应答。验证 DC 能否打开。
import 'dart:async';

import 'package:webrtc_cli/webrtc_cli.dart';

Future<void> main() async {
  print('== repro4: 纯 DataChannel(无媒体) 协商 ==');

  final a = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });
  final b = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });

  final aPending = <RTCIceCandidate>[];
  final bPending = <RTCIceCandidate>[];
  Completer<void>? aGather;
  Completer<void>? bGather;

  a.onIceCandidate = (c) {
    aPending.add(c);
  };
  a.onIceGatheringState = (s) {
    if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) aGather?.complete();
  };
  a.onIceConnectionState = (s) => print('  A ICE: $s');
  a.onConnectionState = (s) => print('  A conn: $s');

  b.onIceCandidate = (c) {
    bPending.add(c);
  };
  b.onIceGatheringState = (s) {
    if (s == RTCIceGatheringState.RTCIceGatheringStateComplete) bGather?.complete();
  };
  b.onIceConnectionState = (s) => print('  B ICE: $s');
  b.onConnectionState = (s) => print('  B conn: $s');

  RTCDataChannel? bDc;
  final bDcOpen = Completer<void>();
  final bGotMessages = <String>[];
  b.onDataChannel = (dc) {
    print('  B onDataChannel fired! label=${dc.label} id=${dc.id}');
    bDc = dc;
    dc.onDataChannelState = (st) {
      print('  B DC state: $st');
      if (st == RTCDataChannelState.RTCDataChannelOpen) {
        if (!bDcOpen.isCompleted) bDcOpen.complete();
      }
    };
    dc.onMessage = (m) {
      bGotMessages.add(m.text);
      print('  B DC got: "${m.text}"');
    };
  };

  // A: 只建 DC, 不加任何媒体轨 —— 与 app 的 data PC 形态一致(纯数据)
  // 对照: app 的 data_offer 是 recvonly 媒体 + application(bundled), 复现这个形态
  await a.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
  await a.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
  final aDc = await a.createDataChannel('data', RTCDataChannelInit());
  print('  A DC created label=${aDc.label} id=${aDc.id}');
  final aDcOpen = Completer<void>();
  aDc.onDataChannelState = (st) {
    print('  A DC state: $st');
    if (st == RTCDataChannelState.RTCDataChannelOpen) {
      if (!aDcOpen.isCompleted) aDcOpen.complete();
    }
  };

  // A offer
  aGather = Completer<void>();
  final offer = await a.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
  print('  A offer type=${offer.type} sdpLen=${offer.sdp?.length}');
  print('  A offer has m=application: ${offer.sdp?.contains('m=application')}');
  await a.setLocalDescription(offer);
  await aGather!.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));

  // B 接收 offer(与 testMain 同序: 先 setRemote, 等 A gather 完才加 A 的 candidate)
  bGather = Completer<void>();
  await b.setRemoteDescription(offer);
  for (final c in aPending) {
    await b.addCandidate(c);
  }
  final answer = await b.createAnswer();
  print('  B answer type=${answer.type} sdpLen=${answer.sdp?.length}');
  print('  B answer has m=application: ${answer.sdp?.contains('m=application')}');
  await b.setLocalDescription(answer);
  await bGather!.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  await Future.delayed(const Duration(milliseconds: 300));
  await a.setRemoteDescription(answer); // 关键: 把 answer 设为 A 的远端描述
  for (final c in bPending) {
    await a.addCandidate(c);
  }

  // 等 DC 打开
  try {
    await aDcOpen.future.timeout(const Duration(seconds: 10));
    print('  A DC OPENED');
  } catch (_) {
    print('  A DC NOT OPENED (timeout)');
  }
  try {
    await bDcOpen.future.timeout(const Duration(seconds: 10));
    print('  B DC OPENED');
  } catch (_) {
    print('  B DC NOT OPENED (timeout)');
  }

  // 双向发消息
  if (aDcOpen.isCompleted) {
    await aDc.send(RTCDataChannelMessage('hello from A'));
  }
  await Future.delayed(const Duration(seconds: 1));
  print('  B got messages: ${bGotMessages.length}');

  await a.close();
  await b.close();
  await a.dispose();
  await b.dispose();
  await dispose();
  print('== repro4 done ==');
}
