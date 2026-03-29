import 'dart:async';
import 'package:flutter/services.dart';
import '../flutter_webrtc.dart';
import 'native/media_stream_impl.dart';

/// 系统音频管理器 - Dart API
/// 提供系统音频捕获和 PCM 文件录制功能
class SysAudioManager {
  /// 获取系统音频流
  /// 
  /// [deviceId] 音频设备 ID，空字符串表示使用默认设备
  /// [streamId] 流 ID，空字符串自动生成
  /// [enablePcmRecording] 是否开启 PCM 录制（测试功能）
  /// [pcmFilePath] PCM 文件路径，如果为空则自动生成（E:/sys_audio_时间戳.pcm）
  /// 
  /// 返回 MediaStream 对象
  static Future<MediaStream> getSysAudioMedia({
    String deviceId = '',
    String streamId = '',
    bool enablePcmRecording = false,
    String? pcmFilePath,
  }) async {
    try {
      final result = await WebRTC.invokeMethod(
        'GetSysAudioMedia',
        <String, dynamic>{
          'deviceId': deviceId,
          'streamId': streamId,
          'enablePcmRecording': enablePcmRecording,
          'pcmFilePath': pcmFilePath ?? '',
        },
      );
      
      if (result == null) {
        throw Exception('GetSysAudioMedia return null, something wrong');
      }
      
      // 创建 MediaStream 对象（参考 getUserMedia 的实现）
      final stream = MediaStreamNative(result['streamId'], result['ownerTag'] ?? 'local');
      stream.setMediaTracks(
        result['audioTracks'] ?? [],
        result['videoTracks'] ?? [],
      );
      
      return stream;
    } on PlatformException catch (e) {
      throw Exception('Failed to get sys audio media: ${e.message}');
    }
  }

  /// 释放系统音频流
  /// 
  /// [streamId] 要释放的流 ID
  static Future<void> releaseSysAudioMedia(String streamId) async {
    try {
      await WebRTC.invokeMethod(
        'ReleaseSysAudioMedia',
        <String, dynamic>{'streamId': streamId},
      );
    } on PlatformException catch (e) {
      throw Exception('Failed to release sys audio media: ${e.message}');
    }
  }

  /// 开启/关闭 PCM 文件录制（测试功能）
  /// 
  /// [enable] true 开启，false 关闭
  /// [filePath] PCM 文件路径，如果为空则自动生成（E:/sys_audio_时间戳.pcm）
  /// 
  /// 返回包含 enabled 和 filePath 的 Map
  static Future<Map<String, dynamic>> enableSysAudioPcmRecording({
    required bool enable,
    String? filePath,
  }) async {
    try {
      final result = await WebRTC.invokeMethod(
        'EnableSysAudioPcmRecording',
        <String, dynamic>{
          'enable': enable,
          'filePath': filePath ?? '',
        },
      );
      
      if (result == null) {
        throw Exception('EnableSysAudioPcmRecording return null, something wrong');
      }
      
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      throw Exception('Failed to enable PCM recording: ${e.message}');
    }
  }
}
