import 'dart:convert';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'desktop_capturer.dart';
import 'frame_cryptor.dart';
import 'media_stream.dart';
import 'native/ffi/webrtc_c.dart';
import 'rtc_peerconnection.dart';

/// 镜像 mediadevices_impl.dart 的 MediaDeviceNative。
class MediaDevicesFfi extends MediaDevices {
  MediaDevicesFfi._() {
    // 注册 factory 级事件回调: 设备热插拔 onDeviceChange → 触发 ondevicechange;
    // 桌源增删/改名 desktopSource* → 路由给 DesktopCapturerFfi。
    final index = WebrtcC.registerEventHandler((json, binary) {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final event = map['event'];
      if (event == 'onDeviceChange') {
        ondevicechange?.call(null);
      } else if (event == 'desktopSourceAdded' ||
          event == 'desktopSourceRemoved' ||
          event == 'desktopSourceNameChanged') {
        DesktopCapturerFfi.instance.handleDesktopEvent(event as String, map);
      } else if (event == 'frameCryptionStateChanged') {
        routeFrameCryptorEvent(map);
      }
    });
    WebrtcC.factorySetEventCallback(WebrtcRuntime.instance.factory, index);
  }
  static final MediaDevicesFfi instance = MediaDevicesFfi._();

  @override
  Future<MediaStream> getUserMedia(
      Map<String, dynamic> mediaConstraints) async {
    final response = WebrtcC.getUserMedia(
        WebrtcRuntime.instance.factory, jsonEncode(mediaConstraints));
    if (response == null) {
      throw Exception('getUserMedia return null, something wrong');
    }
    final stream = MediaStreamFfi(response['streamId'] as String, 'local');
    stream.setMediaTracks(response['audioTracks'], response['videoTracks']);
    return stream;
  }

  @override
  Future<MediaStream> getDisplayMedia(
      Map<String, dynamic> mediaConstraints) async {
    final response = WebrtcC.getDisplayMedia(
        WebrtcRuntime.instance.factory, jsonEncode(mediaConstraints));
    if (response == null) {
      throw Exception('getDisplayMedia failed');
    }
    final stream = MediaStreamFfi(response['streamId'] as String, 'local');
    stream.setMediaTracks(response['audioTracks'], response['videoTracks']);
    return stream;
  }

  @override
  @Deprecated('use enumerateDevices() instead')
  Future<List<dynamic>> getSources() async {
    return WebrtcC.getSources(WebrtcRuntime.instance.factory);
  }

  @override
  Future<List<MediaDeviceInfo>> enumerateDevices() async {
    final source = await getSources();
    return source
        .map((e) => MediaDeviceInfo(
            label: e['label'] as String? ?? '',
            deviceId: e['deviceId'] as String? ?? '',
            kind: e['kind'] as String?,
            groupId: e['groupId'] as String?))
        .toList();
  }

  @override
  Future<MediaDeviceInfo> selectAudioOutput(
      [AudioOutputOptions? options]) async {
    final deviceId = options?.deviceId ?? '';
    WebrtcC.selectAudioOutput(WebrtcRuntime.instance.factory, deviceId);
    return MediaDeviceInfo(label: 'label', deviceId: deviceId);
  }
}

/// 镜像 navigator_impl.dart 的 NavigatorNative。
class NavigatorFfi extends Navigator {
  NavigatorFfi._();
  static final NavigatorFfi instance = NavigatorFfi._();

  @override
  @Deprecated('use mediadevice.getUserMedia() instead')
  Future<MediaStream> getUserMedia(Map<String, dynamic> mediaConstraints) =>
      mediaDevices.getUserMedia(mediaConstraints);

  @override
  @Deprecated('use mediadevice.getDisplayMedia() instead')
  Future<MediaStream> getDisplayMedia(Map<String, dynamic> mediaConstraints) =>
      mediaDevices.getDisplayMedia(mediaConstraints);

  @override
  @Deprecated('use mediadevice.enumerateDevices() instead')
  Future<List<dynamic>> getSources() => mediaDevices.enumerateDevices();

  @override
  MediaDevices get mediaDevices => MediaDevicesFfi.instance;
}

/// 镜像 factory_impl.dart 的 RTCFactoryNative。
class RTCFactoryFfi extends RTCFactory {
  RTCFactoryFfi._();
  static final RTCFactory instance = RTCFactoryFfi._();

  @override
  Future<RTCPeerConnection> createPeerConnection(
      Map<String, dynamic> configuration,
      [Map<String, dynamic>? constraints]) async {
    final defaultConstraints = <String, dynamic>{
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };
    final eventIndex = WebrtcC.reserveEventHandler();
    final handle = WebrtcC.createPeerConnection(
        WebrtcRuntime.instance.factory,
        jsonEncode(configuration),
        jsonEncode(
            constraints == null || constraints.isEmpty ? defaultConstraints : constraints),
        eventIndex);
    if (handle.address == 0) {
      WebrtcC.unregisterEventHandler(eventIndex);
      throw Exception('createPeerConnection failed');
    }
    return RTCPeerConnectionFfi(handle, configuration, eventIndex: eventIndex);
  }

  @override
  Future<MediaStream> createLocalMediaStream(String label) async {
    final response =
        WebrtcC.createLocalMediaStream(WebrtcRuntime.instance.factory);
    if (response == null) {
      throw Exception('createLocalMediaStream return null, something wrong');
    }
    return MediaStreamFfi(response['streamId'] as String, label);
  }

  @override
  Future<RTCRtpCapabilities> getRtpSenderCapabilities(String kind) async {
    final map = WebrtcC.factoryGetRtpSenderCapabilities(
        WebrtcRuntime.instance.factory, kind);
    if (map == null) {
      throw Exception('getRtpSenderCapabilities failed');
    }
    return RTCRtpCapabilities.fromMap(map);
  }

  @override
  Future<RTCRtpCapabilities> getRtpReceiverCapabilities(String kind) async {
    final map = WebrtcC.factoryGetRtpReceiverCapabilities(
        WebrtcRuntime.instance.factory, kind);
    if (map == null) {
      throw Exception('getRtpReceiverCapabilities failed');
    }
    return RTCRtpCapabilities.fromMap(map);
  }

  @override
  MediaRecorder mediaRecorder() => throw UnimplementedError();

  @override
  VideoRenderer videoRenderer() => throw UnimplementedError();

  @override
  Navigator get navigator => NavigatorFfi.instance;

  @override
  FrameCryptorFactory get frameCryptorFactory =>
      FrameCryptorFactoryFfi.instance;
}

// ================= 顶层入口(镜像 factory_impl.dart, 签名与 flutter_webrtc 一致) =================

Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration,
    [Map<String, dynamic> constraints = const {}]) async {
  return RTCFactoryFfi.instance
      .createPeerConnection(configuration, constraints);
}

Future<MediaStream> createLocalMediaStream(String label) async {
  return RTCFactoryFfi.instance.createLocalMediaStream(label);
}

Future<RTCRtpCapabilities> getRtpSenderCapabilities(String kind) async {
  return RTCFactoryFfi.instance.getRtpSenderCapabilities(kind);
}

Future<RTCRtpCapabilities> getRtpReceiverCapabilities(String kind) async {
  return RTCFactoryFfi.instance.getRtpReceiverCapabilities(kind);
}

Navigator get navigator => RTCFactoryFfi.instance.navigator;

MediaDevices get mediaDevices => MediaDevicesFfi.instance;

Future<MediaStream> getUserMedia(Map<String, dynamic> mediaConstraints) {
  return mediaDevices.getUserMedia(mediaConstraints);
}

Future<MediaStream> getDisplayMedia(Map<String, dynamic> mediaConstraints) {
  return mediaDevices.getDisplayMedia(mediaConstraints);
}

DesktopCapturer get desktopCapturer => DesktopCapturerFfi.instance;

Future<List<MediaDeviceInfo>> enumerateDevices() {
  return mediaDevices.enumerateDevices();
}

// ---- 被控端系统音频(MyDesk 专用, 非 webrtc_interface API) ----
Future<MediaStream> getSysAudioMedia(Map<String, dynamic> params) async {
  final response = WebrtcC.getSysAudioMedia(
      WebrtcRuntime.instance.factory, jsonEncode(params));
  if (response == null) {
    throw Exception('getSysAudioMedia failed');
  }
  final stream = MediaStreamFfi(response['streamId'] as String, 'local');
  stream.setMediaTracks(response['audioTracks'], response['videoTracks']);
  return stream;
}

Future<void> releaseSysAudioMedia(String streamId) async {
  WebrtcC.releaseSysAudioMedia(WebrtcRuntime.instance.factory, streamId);
}

Future<int> selectAudioInput(String deviceId) async {
  return WebrtcC.selectAudioInput(WebrtcRuntime.instance.factory, deviceId);
}

/// 释放全局 factory(进程退出时调用)
Future<void> dispose() async {
  WebrtcRuntime.instance.dispose();
  EventBus.close();
}
