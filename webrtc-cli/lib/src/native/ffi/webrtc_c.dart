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

// ================= C 回调签名 =================
typedef EventCallbackNative = Void Function(
    Pointer<Void> userData, Pointer<Utf8> eventJson);
typedef ResultCallbackNative = Void Function(
    Pointer<Void> userData, Int32 err, Pointer<Utf8> json);

// ================= C 函数签名(与 webrtc.h 一一对应) =================
typedef _FactoryCreateNative = Pointer<Void> Function();
typedef _FactoryDestroyNative = Void Function(Pointer<Void> factory);
typedef _CreatePeerConnectionNative = Pointer<Void> Function(
    Pointer<Void> factory,
    Pointer<Utf8> configurationJson,
    Pointer<Utf8> constraintsJson,
    Pointer<NativeFunction<EventCallbackNative>> onEvent,
    Pointer<Void> userData);
typedef _PcDestroyNative = Void Function(Pointer<Void> pc);
typedef _PcCloseNative = Void Function(Pointer<Void> pc);
typedef _GetUserMediaNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> mediaConstraintsJson);
typedef _StreamDisposeNative = Void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _GetSourcesNative = Pointer<Utf8> Function(Pointer<Void> factory);
typedef _SelectAudioInputNative = Int32 Function(
    Pointer<Void> factory, Pointer<Utf8> deviceId);
typedef _CreateLocalMediaStreamNative =
    Pointer<Utf8> Function(Pointer<Void> factory);
typedef _MediaStreamGetTracksNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _MediaStreamDisposeNative = Void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _MediaStreamTrackDisposeNative = Void Function(
    Pointer<Void> factory, Pointer<Utf8> trackId);
typedef _MediaStreamAddTrackNative = Int32 Function(
    Pointer<Void> factory, Pointer<Utf8> streamId, Pointer<Utf8> trackId);
typedef _MediaStreamRemoveTrackNative = Int32 Function(
    Pointer<Void> factory, Pointer<Utf8> streamId, Pointer<Utf8> trackId);
typedef _PcCreateAnswerNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> constraintsJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSetLocalDescriptionNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> sdp,
    Pointer<Utf8> type,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSetRemoteDescriptionNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> sdp,
    Pointer<Utf8> type,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcAddIceCandidateNative = Int32 Function(
    Pointer<Void> pc, Pointer<Utf8> candidateJson);
typedef _PcAddTrackNative = Pointer<Utf8> Function(
    Pointer<Void> pc, Pointer<Utf8> trackId, Pointer<Utf8> streamId);
typedef _PcRemoveTrackNative = Pointer<Utf8> Function(
    Pointer<Void> pc, Pointer<Utf8> senderId);
typedef _PcGetSendersNative = Pointer<Utf8> Function(Pointer<Void> pc);
typedef _PcGetTransceiversNative = Pointer<Utf8> Function(Pointer<Void> pc);
typedef _PcSenderSetParametersNative = Pointer<Utf8> Function(
    Pointer<Void> pc, Pointer<Utf8> senderId, Pointer<Utf8> paramsJson);
typedef _PcTransceiverSetCodecPreferencesNative = Void Function(
    Pointer<Void> pc, Pointer<Utf8> transceiverId, Pointer<Utf8> codecsJson);
typedef _PcGetStatsNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> trackId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _GetSysAudioMediaNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> paramsJson);
typedef _ReleaseSysAudioMediaNative = Void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _GetDesktopSourcesNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> typesJson);
typedef _GetDisplayMediaNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> constraintsJson);
typedef _FactoryGetRtpSenderCapsNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> kind);
typedef _FactoryGetRtpReceiverCapsNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> kind);
typedef _EnableSysAudioPcmNative = Int32 Function(
    Pointer<Void> factory, Int32 enable, Pointer<Utf8> filePath);
typedef _EnableSysAudioPcmDart = int Function(
    Pointer<Void> factory, int enable, Pointer<Utf8> filePath);
typedef _CreateDataChannelNative = Pointer<Utf8> Function(
    Pointer<Void> pc, Pointer<Utf8> label, Pointer<Utf8> initJson);
typedef _DataChannelSetCallbackNative = Int32 Function(
    Pointer<Void> factory,
    Pointer<Utf8> flutterId,
    Pointer<NativeFunction<EventCallbackNative>> cb,
    Pointer<Void> userData);
typedef _DataChannelSendNative = Int32 Function(
    Pointer<Void> factory,
    Pointer<Utf8> flutterId,
    Int32 isBinary,
    Pointer<Uint8> data,
    Int32 len);
typedef _DataChannelBufferedAmountNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> flutterId);
typedef _DataChannelCloseNative = Void Function(
    Pointer<Void> factory, Pointer<Utf8> flutterId);
typedef _FreeStringNative = Void Function(Pointer<Utf8> s);

// Int32 返回的 Dart 侧签名(int 而非 Int32)
typedef _SelectAudioInputDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> deviceId);
typedef _MediaStreamAddTrackDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> streamId, Pointer<Utf8> trackId);
typedef _MediaStreamRemoveTrackDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> streamId, Pointer<Utf8> trackId);
typedef _PcAddIceCandidateDart = int Function(
    Pointer<Void> pc, Pointer<Utf8> candidateJson);
typedef _DataChannelSetCallbackDart = int Function(
    Pointer<Void> factory,
    Pointer<Utf8> flutterId,
    Pointer<NativeFunction<EventCallbackNative>> cb,
    Pointer<Void> userData);
typedef _DataChannelSendDart = int Function(
    Pointer<Void> factory,
    Pointer<Utf8> flutterId,
    int isBinary,
    Pointer<Uint8> data,
    int len);

// Void 返回的 Dart 侧签名(void 而非 dart:ffi 的 Void)
typedef _FactoryDestroyDart = void Function(Pointer<Void> factory);
typedef _PcDestroyDart = void Function(Pointer<Void> pc);
typedef _PcCloseDart = void Function(Pointer<Void> pc);
typedef _StreamDisposeDart = void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _MediaStreamDisposeDart = void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _MediaStreamTrackDisposeDart = void Function(
    Pointer<Void> factory, Pointer<Utf8> trackId);
typedef _PcCreateAnswerDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> constraintsJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSetLocalDescriptionDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> sdp,
    Pointer<Utf8> type,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSetRemoteDescriptionDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> sdp,
    Pointer<Utf8> type,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcTransceiverSetCodecPreferencesDart = void Function(
    Pointer<Void> pc, Pointer<Utf8> transceiverId, Pointer<Utf8> codecsJson);
typedef _PcGetStatsDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> trackId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _ReleaseSysAudioMediaDart = void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _DataChannelCloseDart = void Function(
    Pointer<Void> factory, Pointer<Utf8> flutterId);
typedef _FreeStringDart = void Function(Pointer<Utf8> s);

// ================= 事件总线 =================

/// 跨线程事件分发: 事件回调 → SendPort → 主 isolate → 按 index 路由到 handler。
class _EventBus {
  static final ReceivePort _port = ReceivePort();
  static final Map<int, void Function(String json)> _handlers = {};
  static int _nextIndex = 1;

  // 事件回调(NativeCallable.listener, 可被任意线程调用)
  static void _onEvent(Pointer<Void> userData, Pointer<Utf8> eventJson) {
    final index = userData.address;
    final json = eventJson.toDartString();
    _port.sendPort.send([index, json]);
  }

  // 异步结果回调(err==0 成功)
  static void _onResult(
      Pointer<Void> userData, int err, Pointer<Utf8> json) {
    final index = userData.address;
    final jsonStr = json == nullptr ? '' : json.toDartString();
    _port.sendPort.send([index, err, jsonStr]);
  }

  static final NativeCallable<EventCallbackNative> eventCallable =
      NativeCallable<EventCallbackNative>.listener(_onEvent);
  static final NativeCallable<ResultCallbackNative> resultCallable =
      NativeCallable<ResultCallbackNative>.listener(
          _onResult);

  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    _initialized = true;
    _port.listen((dynamic message) {
      final List<dynamic> data = message as List<dynamic>;
      final index = data[0] as int;
      final handler = _handlers[index];
      if (handler == null) return;
      if (data.length == 2) {
        handler(data[1] as String);
      } else {
        // 异步结果: err, json
        final err = data[1] as int;
        final json = data[2] as String;
        handler(json.isEmpty ? '{"err":$err}' : json);
      }
    });
  }

  static int register(void Function(String json) handler) {
    final index = reserve();
    bind(index, handler);
    return index;
  }

  /// 先占一个索引(createPeerConnection 的 user_data 需要先于对象创建), 稍后 bind。
  static int reserve() {
    init();
    return _nextIndex++;
  }

  static void bind(int index, void Function(String json) handler) {
    _handlers[index] = handler;
  }

  static void unregister(int index) {
    _handlers.remove(index);
  }

  static Pointer<Void> userDataFor(int index) =>
      Pointer<Void>.fromAddress(index);
}

// ================= 库加载 =================

DynamicLibrary _loadLibrary() {
  final override = Platform.environment['WEBRTC_C_LIB'];
  if (override != null && override.isNotEmpty) {
    _preloadLibwebrtc(_dirOf(override));
    return DynamicLibrary.open(override);
  }

  final candidates = <String>[
    // 当前目录 / 可执行文件旁
    'webrtc_c.dll',
    if (Platform.isWindows) ...[
      'webrtc_c.dll',
      '../lib/webrtc_c.dll',
      './lib/webrtc_c.dll',
      'windows/runner/webrtc_c.dll',
      r'E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c\build_vs\Debug\webrtc_c.dll',
      r'E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c\build_vs\Release\webrtc_c.dll',
      r'E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c\cmake-build-debug\webrtc_c.dll',
      r'E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c\cmake-build-release\webrtc_c.dll',
    ],
  ];
  for (final path in candidates) {
    try {
      // 先加载同目录的 libwebrtc.dll(webrtc_c.dll 依赖它, 加载器不搜 DLL 所在目录)
      _preloadLibwebrtc(_dirOf(path));
      return DynamicLibrary.open(path);
    } catch (_) {
      // 继续尝试
    }
  }
  throw StateError('webrtc_c.dll 加载失败, 可用环境变量 WEBRTC_C_LIB 指定路径');
}

String _dirOf(String path) {
  final a = path.lastIndexOf('/');
  final b = path.lastIndexOf('\\');
  final i = a > b ? a : b;
  return i >= 0 ? path.substring(0, i) : '.';
}

void _preloadLibwebrtc(String dir) {
  final libwebrtc = '$dir${Platform.pathSeparator}libwebrtc.dll';
  try {
    DynamicLibrary.open(libwebrtc);
  } catch (_) {
    // libwebrtc 不在同目录时忽略, 由 PATH 决定
  }
}

// ================= 高一层: JSON 字符串跨边界 =================

/// FFI 桥: 每个方法负责 Utf8 <-> Dart String 转换 + malloc 字符串释放。
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
