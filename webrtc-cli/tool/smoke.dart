// 运行冒烟测试: 实际加载 webrtc_c.dll, 逐步验证 FFI 链路。
import 'package:webrtc_cli/webrtc_cli.dart';

Future<void> _step(String name, Future<void> Function() fn) async {
  try {
    await fn();
    // ignore: avoid_print
    print('  [OK]   $name');
  } catch (e) {
    // ignore: avoid_print
    print('  [FAIL] $name -> $e');
  }
}

Future<void> main() async {
  // ignore: avoid_print
  print('== smoke: 加载 webrtc_c.dll ==');

  await _step('createPeerConnection', () async {
    final pc = await createPeerConnection(<String, dynamic>{'iceServers': []});
    await pc.close();
    await pc.dispose();
  });

  await _step('getRtpSenderCapabilities(video)', () async {
    final c = await getRtpSenderCapabilities('video');
    // ignore: avoid_print
    print('        codecs=${c.codecs?.map((e) => e.mimeType).toList()}');
  });

  await _step('getUserMedia(video)', () async {
    final s = await getUserMedia(<String, dynamic>{'audio': false, 'video': true});
    // ignore: avoid_print
    print('        streamId=${s.id} videoTracks=${s.getVideoTracks().length}');
    await s.dispose();
  });

  await _step('desktopCapturer.getSources([Screen])', () async {
    final sources =
        await desktopCapturer.getSources(types: [SourceType.Screen]);
    // ignore: avoid_print
    print('        sources=${sources.map((s) => s.name).toList()}');
  });

  await _step('getDisplayMedia', () async {
    final s = await getDisplayMedia(<String, dynamic>{'video': true});
    // ignore: avoid_print
    print('        streamId=${s.id} videoTracks=${s.getVideoTracks().length}');
    await s.dispose();
  });

  await _step('SysAudioManager.getSysAudioMedia', () async {
    final s = await SysAudioManager.getSysAudioMedia();
    // ignore: avoid_print
    print('        streamId=${s.id} audioTracks=${s.getAudioTracks().length}');
    await SysAudioManager.releaseSysAudioMedia(s.id);
  });

  await _step('enumerateDevices', () async {
    final devs = await enumerateDevices();
    // ignore: avoid_print
    print('        ${devs.map((d) => '${d.kind}:${d.label}').toList()}');
  });

  await dispose();
  // ignore: avoid_print
  print('== smoke done ==');
}
