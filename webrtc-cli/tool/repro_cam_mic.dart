// 复现: 麦克风 vs 摄像头 完整编码链路(getUserMedia -> addTrack -> offer/setLocalDescription)
// docs 记录摄像头在 setLocalDescription 后帧流入编码器时崩(sink_filter_ds.cc:735 线程 CHECK)。
// 本脚本分别跑 mic / cam, 看谁崩、崩在哪一步。
import 'dart:io';

import 'package:webrtc_cli/webrtc_cli.dart';

Future<void> _run(String name, MediaStream stream) async {
  print('== [$name] getUserMedia 成功 streamId=${stream.id} ==');
  final pc = await createPeerConnection(<String, dynamic>{'iceServers': []});
  print('== [$name] PC 已创建 ==');
  final tracks = name == 'mic'
      ? stream.getAudioTracks()
      : stream.getVideoTracks();
  for (final t in tracks) {
    await pc.addTrack(t, stream);
    print('== [$name] addTrack: ${t.kind} ${t.id} ==');
  }
  print('== [$name] createOffer... ==');
  final offer = await pc.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
  print('== [$name] offer ok, setLocalDescription... ==');
  await pc.setLocalDescription(offer);
  print('== [$name] setLocalDescription 完成, 等待 5s 看是否崩 ==');
  await Future.delayed(const Duration(seconds: 5));
  print('== [$name] 存活 5s, 未崩 ==');
  await pc.close();
  await pc.dispose();
  await stream.dispose();
  print('== [$name] 清理完成 ==');
}

Future<void> main() async {
  print('== 开始: 麦克风 vs 摄像头 完整编码链路对比 ==');

  print('>>> 1. 麦克风 getUserMedia(audio)');
  final mic = await getUserMedia(<String, dynamic>{'audio': true, 'video': false});
  await _run('mic', mic);
  print('>>> mic 段结束\n');

  stdout.write('>>> 2. 摄像头 getUserMedia(video) — 3 秒后开始, 观察是否崩\n');
  await Future.delayed(const Duration(seconds: 3));
  final cam = await getUserMedia(<String, dynamic>{'audio': false, 'video': true});
  await _run('cam', cam);
  print('>>> cam 段结束\n');

  await dispose();
  print('== 对比结束 ==');
}
