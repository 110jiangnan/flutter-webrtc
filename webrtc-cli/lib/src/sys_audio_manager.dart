import 'dart:convert';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream.dart';
import 'native/ffi/webrtc_c.dart';

/// 系统音频管理器, 镜像 flutter-webrtc lib/src/sys_audio_manager.dart。
class SysAudioManager {
  /// 获取系统音频流。
  ///
  /// [deviceId] 音频设备 ID, 空字符串使用默认设备
  /// [streamId] 流 ID, 空字符串自动生成
  /// [enablePcmRecording] 是否开启 PCM 录制
  /// [pcmFilePath] PCM 文件路径, 为空自动生成
  static Future<MediaStream> getSysAudioMedia({
    String deviceId = '',
    String streamId = '',
    bool enablePcmRecording = false,
    String? pcmFilePath,
  }) async {
    final result = WebrtcC.getSysAudioMedia(
        WebrtcRuntime.instance.factory,
        jsonEncode({
          'deviceId': deviceId,
          'streamId': streamId,
          'enablePcmRecording': enablePcmRecording,
          'pcmFilePath': pcmFilePath ?? '',
        }));
    if (result == null) {
      throw Exception('GetSysAudioMedia return null, something wrong');
    }
    final stream =
        MediaStreamFfi(result['streamId'] as String, result['ownerTag'] ?? 'local');
    stream.setMediaTracks(result['audioTracks'] ?? [], result['videoTracks'] ?? []);
    return stream;
  }

  /// 释放系统音频流。
  static Future<void> releaseSysAudioMedia(String streamId) async {
    WebrtcC.releaseSysAudioMedia(WebrtcRuntime.instance.factory, streamId);
  }

  /// 开启/关闭 PCM 文件录制, 返回 {enabled, filePath}。
  static Future<Map<String, dynamic>> enableSysAudioPcmRecording({
    required bool enable,
    String? filePath,
  }) async {
    WebrtcC.enableSysAudioPcmRecording(
        WebrtcRuntime.instance.factory, enable, filePath ?? '');
    return {'enabled': enable, 'filePath': filePath ?? ''};
  }

  /// C ABI 未实现(主控播放端用)
  static Future<void> addAudioSink(String trackId) async {
    throw UnimplementedError('addAudioSink: 主控播放端用, C ABI 未实现');
  }
}
