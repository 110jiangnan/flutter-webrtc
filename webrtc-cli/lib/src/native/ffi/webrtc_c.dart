import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ============================================================================
// 底层 FFI 主库 + 对外门面(按功能拆分成多个 part 文件)。
//
// 拆分后布局(每个 part 共享本库作用域, 可直接用本库的私有 typedef/辅助):
//   webrtc_c_base.dart       基础类定义(typedef/EventBus/库加载/辅助)
//   webrtc_c_media.dart      工厂/设备/本地流/系统音频/RTP capabilities
//   webrtc_c_pc.dart         peerconnection(建连/sdp/ICE/sender/transceiver/stats)
//   webrtc_c_datachannel.dart  数据通道
//   webrtc_c_desktop.dart    屏幕采集(源列表/getDisplayMedia)
//
// 本文件保留一个薄的静态门面 `WebrtcC`, 方法逐一委托给上面的功能类,
// 这样既有调用点 `WebrtcC.x()` 全部保持不变, 又满足按功能拆分、文件更小的诉求。
// ============================================================================
part 'webrtc_c_base.dart';
part 'webrtc_c_media.dart';
part 'webrtc_c_pc.dart';
part 'webrtc_c_datachannel.dart';
part 'webrtc_c_desktop.dart';
part 'webrtc_c_framecryptor.dart';

/// 底层 FFI 的对外门面。
class WebrtcC {
  WebrtcC._();

  // ---- 事件总线入口(基础) ----
  static int registerEventHandler(EventHandler handler) =>
      EventBus.register(handler);
  static int reserveEventHandler() => EventBus.reserve();
  static void bindEventHandler(int index, EventHandler handler) =>
      EventBus.bind(index, handler);
  static void unregisterEventHandler(int index) => EventBus.unregister(index);

  // ---- factory / 设备 / 本地流 / 系统音频 / RTP caps(媒体域) ----
  static Pointer<Void> factoryCreate() => WebrtcCMedia.factoryCreate();
  static void factoryDestroy(Pointer<Void> factory) =>
      WebrtcCMedia.factoryDestroy(factory);
  static int factorySetEventCallback(Pointer<Void> factory, int eventIndex) =>
      WebrtcCMedia.factorySetEventCallback(factory, eventIndex);
  static Map<String, dynamic>? getUserMedia(
          Pointer<Void> factory, String mediaConstraintsJson) =>
      WebrtcCMedia.getUserMedia(factory, mediaConstraintsJson);
  static void streamDispose(Pointer<Void> factory, String streamId) =>
      WebrtcCMedia.streamDispose(factory, streamId);
  static List<dynamic> getSources(Pointer<Void> factory) =>
      WebrtcCMedia.getSources(factory);
  static int selectAudioInput(Pointer<Void> factory, String deviceId) =>
      WebrtcCMedia.selectAudioInput(factory, deviceId);
  static int selectAudioOutput(Pointer<Void> factory, String deviceId) =>
      WebrtcCMedia.selectAudioOutput(factory, deviceId);
  static Map<String, dynamic>? createLocalMediaStream(Pointer<Void> factory) =>
      WebrtcCMedia.createLocalMediaStream(factory);
  static Map<String, dynamic>? mediaStreamGetTracks(
          Pointer<Void> factory, String streamId) =>
      WebrtcCMedia.mediaStreamGetTracks(factory, streamId);
  static void mediaStreamDispose(Pointer<Void> factory, String streamId) =>
      WebrtcCMedia.mediaStreamDispose(factory, streamId);
  static void mediaStreamTrackDispose(Pointer<Void> factory, String trackId) =>
      WebrtcCMedia.mediaStreamTrackDispose(factory, trackId);
  static bool mediaStreamTrackSetEnable(
          Pointer<Void> factory, String trackId, bool enabled) =>
      WebrtcCMedia.mediaStreamTrackSetEnable(factory, trackId, enabled);
  static bool trackSetVolume(
          Pointer<Void> factory, String trackId, double volume) =>
      WebrtcCMedia.trackSetVolume(factory, trackId, volume);
  static bool mediaStreamAddTrack(
          Pointer<Void> factory, String streamId, String trackId) =>
      WebrtcCMedia.mediaStreamAddTrack(factory, streamId, trackId);
  static bool mediaStreamRemoveTrack(
          Pointer<Void> factory, String streamId, String trackId) =>
      WebrtcCMedia.mediaStreamRemoveTrack(factory, streamId, trackId);
  static Map<String, dynamic>? getSysAudioMedia(
          Pointer<Void> factory, String paramsJson) =>
      WebrtcCMedia.getSysAudioMedia(factory, paramsJson);
  static void releaseSysAudioMedia(Pointer<Void> factory, String streamId) =>
      WebrtcCMedia.releaseSysAudioMedia(factory, streamId);
  static int enableSysAudioPcmRecording(
          Pointer<Void> factory, bool enable, String filePath) =>
      WebrtcCMedia.enableSysAudioPcmRecording(factory, enable, filePath);
  static Map<String, dynamic>? factoryGetRtpSenderCapabilities(
          Pointer<Void> factory, String kind) =>
      WebrtcCMedia.factoryGetRtpSenderCapabilities(factory, kind);
  static Map<String, dynamic>? factoryGetRtpReceiverCapabilities(
          Pointer<Void> factory, String kind) =>
      WebrtcCMedia.factoryGetRtpReceiverCapabilities(factory, kind);

  // ---- 屏幕采集(桌面域) ----
  static List<dynamic> getDesktopSources(Pointer<Void> factory, String typesJson) =>
      WebrtcCDesktop.getDesktopSources(factory, typesJson);
  static bool updateDesktopSources(Pointer<Void> factory, String typesJson) =>
      WebrtcCDesktop.updateDesktopSources(factory, typesJson);
  static Map<String, dynamic>? getDisplayMedia(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCDesktop.getDisplayMedia(factory, constraintsJson);

  // ---- peerconnection(PC 域) ----
  static Pointer<Void> createPeerConnection(Pointer<Void> factory,
          String configurationJson, String constraintsJson, int eventIndex) =>
      WebrtcCPc.createPeerConnection(
          factory, configurationJson, constraintsJson, eventIndex);
  static void pcDestroy(Pointer<Void> pc) => WebrtcCPc.pcDestroy(pc);
  static void pcClose(Pointer<Void> pc) => WebrtcCPc.pcClose(pc);
  static Future<Map<String, dynamic>> pcCreateAnswer(
          Pointer<Void> pc, String constraintsJson) =>
      WebrtcCPc.pcCreateAnswer(pc, constraintsJson);
  static Future<void> pcSetLocalDescription(
          Pointer<Void> pc, String sdp, String type) =>
      WebrtcCPc.pcSetLocalDescription(pc, sdp, type);
  static Future<void> pcSetRemoteDescription(
          Pointer<Void> pc, String sdp, String type) =>
      WebrtcCPc.pcSetRemoteDescription(pc, sdp, type);
  static int pcAddIceCandidate(Pointer<Void> pc, String candidateJson) =>
      WebrtcCPc.pcAddIceCandidate(pc, candidateJson);
  static Map<String, dynamic>? pcAddTrack(
          Pointer<Void> pc, String trackId, String? streamId) =>
      WebrtcCPc.pcAddTrack(pc, trackId, streamId);
  static bool pcRemoveTrack(Pointer<Void> pc, String senderId) =>
      WebrtcCPc.pcRemoveTrack(pc, senderId);
  static List<dynamic> pcGetSenders(Pointer<Void> pc) =>
      WebrtcCPc.pcGetSenders(pc);
  static List<dynamic> pcGetTransceivers(Pointer<Void> pc) =>
      WebrtcCPc.pcGetTransceivers(pc);
  static bool pcSenderSetParameters(
          Pointer<Void> pc, String senderId, String paramsJson) =>
      WebrtcCPc.pcSenderSetParameters(pc, senderId, paramsJson);
  static void pcTransceiverSetCodecPreferences(
          Pointer<Void> pc, String transceiverId, String codecsJson) =>
      WebrtcCPc.pcTransceiverSetCodecPreferences(pc, transceiverId, codecsJson);
  static Future<List<dynamic>> pcGetStats(Pointer<Void> pc, String trackId) =>
      WebrtcCPc.pcGetStats(pc, trackId);
  static Future<Map<String, dynamic>> pcCreateOffer(
          Pointer<Void> pc, String constraintsJson) =>
      WebrtcCPc.pcCreateOffer(pc, constraintsJson);
  static Future<Map<String, dynamic>> pcGetLocalDescription(Pointer<Void> pc) =>
      WebrtcCPc.pcGetLocalDescription(pc);
  static Future<Map<String, dynamic>> pcGetRemoteDescription(
          Pointer<Void> pc) =>
      WebrtcCPc.pcGetRemoteDescription(pc);
  static Map<String, dynamic>? pcAddTransceiver(
          Pointer<Void> pc, String? trackId, String mediaType, String initJson) =>
      WebrtcCPc.pcAddTransceiver(pc, trackId, mediaType, initJson);
  static List<dynamic> pcGetReceivers(Pointer<Void> pc) =>
      WebrtcCPc.pcGetReceivers(pc);
  static Future<bool> pcSenderSetTrack(
          Pointer<Void> pc, String senderId, String? trackId) =>
      WebrtcCPc.pcSenderSetTrack(pc, senderId, trackId);
  static Future<bool> pcSenderSetStream(
          Pointer<Void> pc, String senderId, String streamIdsJson) =>
      WebrtcCPc.pcSenderSetStream(pc, senderId, streamIdsJson);
  static Future<void> pcTransceiverStop(
          Pointer<Void> pc, String transceiverId) =>
      WebrtcCPc.pcTransceiverStop(pc, transceiverId);
  static Future<String> pcTransceiverGetCurrentDirection(
          Pointer<Void> pc, String transceiverId) =>
      WebrtcCPc.pcTransceiverGetCurrentDirection(pc, transceiverId);
  static Future<void> pcTransceiverSetDirection(
          Pointer<Void> pc, String transceiverId, String direction) =>
      WebrtcCPc.pcTransceiverSetDirection(pc, transceiverId, direction);
  static Future<void> pcSetConfiguration(
          Pointer<Void> pc, String configurationJson) =>
      WebrtcCPc.pcSetConfiguration(pc, configurationJson);
  static bool pcAddStream(Pointer<Void> pc, String streamId) =>
      WebrtcCPc.pcAddStream(pc, streamId);
  static bool pcRemoveStream(Pointer<Void> pc, String streamId) =>
      WebrtcCPc.pcRemoveStream(pc, streamId);
  static void pcRestartIce(Pointer<Void> pc) => WebrtcCPc.pcRestartIce(pc);
  static bool pcSenderCanInsertDtmf(Pointer<Void> pc, String senderId) =>
      WebrtcCPc.pcSenderCanInsertDtmf(pc, senderId);
  static bool pcSenderInsertDtmf(
          Pointer<Void> pc, String senderId, String tones, int duration, int gap) =>
      WebrtcCPc.pcSenderInsertDtmf(pc, senderId, tones, duration, gap);
  static String pcGetSignalingState(Pointer<Void> pc) =>
      WebrtcCPc.pcGetSignalingState(pc);
  static String pcGetIceGatheringState(Pointer<Void> pc) =>
      WebrtcCPc.pcGetIceGatheringState(pc);
  static String pcGetIceConnectionState(Pointer<Void> pc) =>
      WebrtcCPc.pcGetIceConnectionState(pc);
  static String pcGetConnectionState(Pointer<Void> pc) =>
      WebrtcCPc.pcGetConnectionState(pc);

  // ---- data channel(数据通道域) ----
  static Map<String, dynamic>? createDataChannel(
          Pointer<Void> pc, String label, String initJson) =>
      WebrtcCDataChannel.createDataChannel(pc, label, initJson);
  static int dataChannelSetCallback(
          Pointer<Void> factory, String flutterId, int eventIndex) =>
      WebrtcCDataChannel.dataChannelSetCallback(factory, flutterId, eventIndex);
  static int dataChannelSend(
          Pointer<Void> factory, String flutterId, bool isBinary, Uint8List data) =>
      WebrtcCDataChannel.dataChannelSend(factory, flutterId, isBinary, data);
  static int dataChannelBufferedAmount(
          Pointer<Void> factory, String flutterId) =>
      WebrtcCDataChannel.dataChannelBufferedAmount(factory, flutterId);
  static void dataChannelClose(Pointer<Void> factory, String flutterId) =>
      WebrtcCDataChannel.dataChannelClose(factory, flutterId);

  // ---- E2EE 帧加密(FrameCryptor / KeyProvider) ----
  static Map<String, dynamic>? frameCryptorFactoryCreateFrameCryptor(
          Pointer<Void> pc, String constraintsJson) =>
      WebrtcCFrameCryptor.factoryCreateFrameCryptor(pc, constraintsJson);
  static Map<String, dynamic>? frameCryptorSetKeyIndex(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.setKeyIndex(factory, constraintsJson);
  static Map<String, dynamic>? frameCryptorGetKeyIndex(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.getKeyIndex(factory, constraintsJson);
  static Map<String, dynamic>? frameCryptorSetEnabled(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.setEnabled(factory, constraintsJson);
  static Map<String, dynamic>? frameCryptorGetEnabled(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.getEnabled(factory, constraintsJson);
  static Map<String, dynamic>? frameCryptorDispose(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.dispose(factory, constraintsJson);
  static Map<String, dynamic>? frameCryptorFactoryCreateKeyProvider(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.factoryCreateKeyProvider(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderSetSharedKey(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.setSharedKey(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderRatchetSharedKey(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.ratchetSharedKey(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderExportSharedKey(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.exportSharedKey(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderSetKey(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.setKey(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderRatchetKey(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.ratchetKey(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderExportKey(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.exportKey(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderSetSifTrailer(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.setSifTrailer(factory, constraintsJson);
  static Map<String, dynamic>? keyProviderDispose(
          Pointer<Void> factory, String constraintsJson) =>
      WebrtcCFrameCryptor.keyProviderDispose(factory, constraintsJson);
}

/// 运行时单例: 持有全局 factory 句柄。
class WebrtcRuntime {
  WebrtcRuntime._();
  static final WebrtcRuntime instance = WebrtcRuntime._();

  Pointer<Void>? _factory;

  Pointer<Void> get factory {
    final f = _factory;
    if (f != null) return f;
    final created = WebrtcC.factoryCreate();
    if (created == nullptr) {
      throw StateError('webrtc_factory_create 失败');
    }
    _factory = created;
    return created;
  }

  bool get isInitialized => _factory != null;

  void dispose() {
    final f = _factory;
    if (f != null) {
      WebrtcC.factoryDestroy(f);
      _factory = null;
    }
  }
}
