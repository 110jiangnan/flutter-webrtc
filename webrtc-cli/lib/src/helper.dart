import 'package:webrtc_interface/webrtc_interface.dart';

import 'factory.dart';
import 'native/ffi/webrtc_c.dart';

/// 镜像 flutter-webrtc lib/src/helper.dart 的 Helper(仅 PC 支持的子集)。
class Helper {
  static Future<List<MediaDeviceInfo>> enumerateDevices(String type) async {
    final devices = await mediaDevices.enumerateDevices();
    return devices.where((d) => d.kind == type).toList();
  }

  static Future<List<MediaDeviceInfo>> get cameras =>
      enumerateDevices('videoinput');

  static Future<List<MediaDeviceInfo>> get audiooutputs =>
      enumerateDevices('audiooutput');

  /// 切换摄像头。
  /// [deviceId]+[stream] 都传时: 停止原视频轨 → 用新 deviceId 重新采集 → 加回流。
  /// 只传 [track](应用层常见用法): 桌面 C ABI 无 mediaStreamTrackSwitchCamera,
  /// 参考 flutter_webrtc 桌面实现也是 NotImplemented, 这里安全返回 false 不打扰现有采集。
  static Future<bool> switchCamera(MediaStreamTrack track,
      [String? deviceId, MediaStream? stream]) async {
    if (track.kind != 'video') {
      throw 'The is not a video track => $track';
    }
    if (deviceId == null || stream == null) {
      return false;
    }

    final cams = await cameras;
    if (!cams.any((e) => e.deviceId == deviceId)) {
      throw 'The provided deviceId is not available, make sure to retreive the deviceId from Helper.cameras()';
    }

    stream.getVideoTracks().forEach((t) {
      t.stop();
      stream.removeTrack(t);
    });

    final mediaConstraints = <String, dynamic>{
      'audio': false, // 不需要重新采集音频
      'video': {'deviceId': deviceId},
    };
    final newStream = await openCamera(mediaConstraints);
    final newCamTrack = newStream.getVideoTracks()[0];
    await stream.addTrack(newCamTrack, addToNative: true);
    return true;
  }

  static Future<MediaStream> openCamera(
      Map<String, dynamic> mediaConstraints) {
    return mediaDevices.getUserMedia(mediaConstraints);
  }

  /// 选麦克风输入设备
  static Future<void> selectAudioInput(String deviceId) async {
    WebrtcC.selectAudioInput(WebrtcRuntime.instance.factory, deviceId);
  }

  /// 选播放设备
  static Future<void> selectAudioOutput(String deviceId) async {
    WebrtcC.selectAudioOutput(WebrtcRuntime.instance.factory, deviceId);
  }

  // ---- 已接通 C ABI ----
  static Future<void> setVolume(double volume, MediaStreamTrack track) async {
    WebrtcC.trackSetVolume(WebrtcRuntime.instance.factory, track.id!, volume);
  }
  // ---- 仅移动端 / 平台特有无 C ABI, 保留签名抛未实现 ----
  static Future<void> setMicrophoneMute(bool mute, MediaStreamTrack track) =>
      throw UnimplementedError('setMicrophoneMute: C ABI 未实现');
  static Future<void> setSpeakerphoneOn(bool enable) =>
      throw UnimplementedError('setSpeakerphoneOn: 仅移动端');
  static Future<void> ensureAudioSession() =>
      throw UnimplementedError('ensureAudioSession: 仅 iOS');
  static Future<void> setZoom(MediaStreamTrack videoTrack, double zoomLevel) =>
      throw UnimplementedError('setZoom: 仅移动端');
}
