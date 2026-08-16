// 应用层 API 冒烟测试: 覆盖 mydesk_server/bin(RtcHookRegister/AppServerTempCfg)
// 实际用到的 webrtc_cli 符号, 确保用法与 flutter_webrtc 一致、能编译。
import 'package:webrtc_cli/webrtc_cli.dart';

Future<void> smokeApplicationUsage() async {
  // RtcHookRegister: createPeerConnection / navigator.mediaDevices
  final pc = await createPeerConnection(<String, dynamic>{'iceServers': []});
  final micStream = await navigator.mediaDevices
      .getUserMedia(<String, dynamic>{'audio': true, 'video': false});
  final camStream = await navigator.mediaDevices
      .getUserMedia(<String, dynamic>{'audio': false, 'video': true});
  final screenStream = await navigator.mediaDevices
      .getDisplayMedia(<String, dynamic>{'video': true});

  // desktopCapturer.getSources
  final sources =
      await desktopCapturer.getSources(types: [SourceType.Screen]);
  for (final s in sources) {
    // ignore: avoid_print
    print('${s.id} ${s.name} ${s.thumbnailSize.toMap()}');
  }

  // Helper.switchCamera(单参数)
  final track = camStream.getVideoTracks().first;
  await Helper.switchCamera(track);

  // setPreferredCodecs: getRtpSenderCapabilities + getTransceivers + setCodecPreferences
  final RTCRtpCapabilities vcaps = await getRtpSenderCapabilities('video');
  await getRtpReceiverCapabilities('audio');
  final codecs = vcaps.codecs?.map((e) => e.mimeType).join(',');
  // ignore: avoid_print
  print('video codecs: $codecs');
  final transceivers = await pc.getTransceivers();
  for (final transceiver in transceivers) {
    if (transceiver.receiver.track?.kind != 'video') continue;
    await transceiver.setCodecPreferences(vcaps.codecs ?? []);
  }

  // SysAudioManager
  final sysStream = await SysAudioManager.getSysAudioMedia();
  await SysAudioManager.releaseSysAudioMedia(sysStream.id);

  // answer 流程
  final answer = await pc.createAnswer();
  await pc.setLocalDescription(RTCSessionDescription(answer.sdp!, answer.type!));
  await pc.setRemoteDescription(RTCSessionDescription('sdp', 'offer'));
  await pc.addCandidate(RTCIceCandidate('candidate', '0', 0));
  await pc.addTrack(track, camStream);
  await pc.getSenders();
  await pc.close();
  await pc.dispose();

  await micStream.dispose();
  await camStream.dispose();
  await screenStream.dispose();
}
