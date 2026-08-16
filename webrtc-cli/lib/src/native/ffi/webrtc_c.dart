import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// 底层 FFI 绑定 + 事件总线。
/// 对应 C 头文件 webrtc-c/include/webrtc.h。
///
/// 事件(PC 事件 / data channel 消息 / 异步结果)由 C++ signaling 线程触发,
/// 用 NativeCallable.listener + SendPort 跨线程转到主 isolate 再分发。

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
      'windows/runner/webrtc_c.dll',
      r'E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c\build_vs\Debug\webrtc_c.dll',
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
  static final DynamicLibrary _lib = _loadLibrary();

  static final _factoryCreate = _lib
      .lookupFunction<_FactoryCreateNative, _FactoryCreateNative>(
          'webrtc_factory_create');
  static final _factoryDestroy = _lib
      .lookupFunction<_FactoryDestroyNative, _FactoryDestroyDart>(
          'webrtc_factory_destroy');
  static final _createPeerConnection = _lib.lookupFunction<
      _CreatePeerConnectionNative,
      _CreatePeerConnectionNative>('webrtc_create_peer_connection');
  static final _pcDestroy =
      _lib.lookupFunction<_PcDestroyNative, _PcDestroyDart>('webrtc_pc_destroy');
  static final _pcClose =
      _lib.lookupFunction<_PcCloseNative, _PcCloseDart>('webrtc_pc_close');
  static final _getUserMedia = _lib.lookupFunction<_GetUserMediaNative,
      _GetUserMediaNative>('webrtc_get_user_media');
  static final _streamDispose = _lib.lookupFunction<_StreamDisposeNative, _StreamDisposeDart>('webrtc_stream_dispose');
  static final _getSources = _lib
      .lookupFunction<_GetSourcesNative, _GetSourcesNative>('webrtc_get_sources');
  static final _selectAudioInput = _lib.lookupFunction<
      _SelectAudioInputNative, _SelectAudioInputDart>('webrtc_select_audio_input');
  static final _createLocalMediaStream = _lib.lookupFunction<
      _CreateLocalMediaStreamNative,
      _CreateLocalMediaStreamNative>('webrtc_create_local_media_stream');
  static final _mediaStreamGetTracks = _lib.lookupFunction<
      _MediaStreamGetTracksNative,
      _MediaStreamGetTracksNative>('webrtc_media_stream_get_tracks');
  static final _mediaStreamDispose = _lib.lookupFunction<_MediaStreamDisposeNative, _MediaStreamDisposeDart>('webrtc_media_stream_dispose');
  static final _mediaStreamTrackDispose = _lib.lookupFunction<
      _MediaStreamTrackDisposeNative,
      _MediaStreamTrackDisposeDart>('webrtc_media_stream_track_dispose');
  static final _mediaStreamAddTrack = _lib.lookupFunction<
      _MediaStreamAddTrackNative,
      _MediaStreamAddTrackDart>('webrtc_media_stream_add_track');
  static final _mediaStreamRemoveTrack = _lib.lookupFunction<
      _MediaStreamRemoveTrackNative,
      _MediaStreamRemoveTrackDart>('webrtc_media_stream_remove_track');
  static final _pcCreateAnswer = _lib.lookupFunction<_PcCreateAnswerNative, _PcCreateAnswerDart>('webrtc_pc_create_answer');
  static final _pcSetLocalDescription = _lib.lookupFunction<
      _PcSetLocalDescriptionNative,
      _PcSetLocalDescriptionDart>('webrtc_pc_set_local_description');
  static final _pcSetRemoteDescription = _lib.lookupFunction<
      _PcSetRemoteDescriptionNative,
      _PcSetRemoteDescriptionDart>('webrtc_pc_set_remote_description');
  static final _pcAddIceCandidate = _lib.lookupFunction<
      _PcAddIceCandidateNative,
      _PcAddIceCandidateDart>('webrtc_pc_add_ice_candidate');
  static final _pcAddTrack = _lib.lookupFunction<_PcAddTrackNative,
      _PcAddTrackNative>('webrtc_pc_add_track');
  static final _pcRemoveTrack = _lib.lookupFunction<_PcRemoveTrackNative,
      _PcRemoveTrackNative>('webrtc_pc_remove_track');
  static final _pcGetSenders = _lib.lookupFunction<_PcGetSendersNative,
      _PcGetSendersNative>('webrtc_pc_get_senders');
  static final _pcGetTransceivers = _lib.lookupFunction<_PcGetTransceiversNative,
      _PcGetTransceiversNative>('webrtc_pc_get_transceivers');
  static final _pcSenderSetParameters = _lib.lookupFunction<
      _PcSenderSetParametersNative,
      _PcSenderSetParametersNative>('webrtc_pc_sender_set_parameters');
  static final _pcTransceiverSetCodecPreferences = _lib.lookupFunction<
      _PcTransceiverSetCodecPreferencesNative,
      _PcTransceiverSetCodecPreferencesDart>(
          'webrtc_pc_transceiver_set_codec_preferences');
  static final _pcGetStats = _lib.lookupFunction<_PcGetStatsNative, _PcGetStatsDart>('webrtc_pc_get_stats');
  static final _getSysAudioMedia = _lib.lookupFunction<_GetSysAudioMediaNative,
      _GetSysAudioMediaNative>('webrtc_get_sys_audio_media');
  static final _releaseSysAudioMedia = _lib.lookupFunction<
      _ReleaseSysAudioMediaNative,
      _ReleaseSysAudioMediaDart>('webrtc_release_sys_audio_media');
  static final _getDesktopSources = _lib.lookupFunction<
      _GetDesktopSourcesNative,
      _GetDesktopSourcesNative>('webrtc_get_desktop_sources');
  static final _getDisplayMedia = _lib.lookupFunction<_GetDisplayMediaNative,
      _GetDisplayMediaNative>('webrtc_get_display_media');
  static final _factoryGetRtpSenderCaps = _lib.lookupFunction<
      _FactoryGetRtpSenderCapsNative,
      _FactoryGetRtpSenderCapsNative>('webrtc_factory_get_rtp_sender_capabilities');
  static final _factoryGetRtpReceiverCaps = _lib.lookupFunction<
      _FactoryGetRtpReceiverCapsNative,
      _FactoryGetRtpReceiverCapsNative>('webrtc_factory_get_rtp_receiver_capabilities');
  static final _enableSysAudioPcm = _lib.lookupFunction<_EnableSysAudioPcmNative,
      _EnableSysAudioPcmDart>('webrtc_enable_sys_audio_pcm_recording');
  static final _createDataChannel = _lib.lookupFunction<_CreateDataChannelNative,
      _CreateDataChannelNative>('webrtc_create_data_channel');
  static final _dataChannelSetCallback = _lib.lookupFunction<
      _DataChannelSetCallbackNative,
      _DataChannelSetCallbackDart>('webrtc_data_channel_set_callback');
  static final _dataChannelSend = _lib.lookupFunction<_DataChannelSendNative,
      _DataChannelSendDart>('webrtc_data_channel_send');
  static final _dataChannelBufferedAmount = _lib.lookupFunction<
      _DataChannelBufferedAmountNative,
      _DataChannelBufferedAmountNative>('webrtc_data_channel_buffered_amount');
  static final _dataChannelClose = _lib.lookupFunction<_DataChannelCloseNative, _DataChannelCloseDart>('webrtc_data_channel_close');
  static final _freeString =
      _lib.lookupFunction<_FreeStringNative, _FreeStringDart>('webrtc_free_string');

  // ---- 字符串辅助 ----
  static String? _takeString(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return null;
    final s = ptr.toDartString();
    _freeString(ptr);
    return s;
  }

  // ---- factory ----
  static Pointer<Void> factoryCreate() => _factoryCreate();
  static void factoryDestroy(Pointer<Void> factory) => _factoryDestroy(factory);

  // ---- createPeerConnection / PC ----
  static Pointer<Void> createPeerConnection(
      Pointer<Void> factory, String configurationJson, String constraintsJson,
      int eventIndex) {
    final cfg = configurationJson.toNativeUtf8();
    final cons = constraintsJson.toNativeUtf8();
    try {
      return _createPeerConnection(
          factory, cfg, cons, _EventBus.eventCallable.nativeFunction,
          _EventBus.userDataFor(eventIndex));
    } finally {
      malloc.free(cfg);
      malloc.free(cons);
    }
  }

  static void pcDestroy(Pointer<Void> pc) => _pcDestroy(pc);
  static void pcClose(Pointer<Void> pc) => _pcClose(pc);

  static Future<Map<String, dynamic>> pcCreateAnswer(
      Pointer<Void> pc, String constraintsJson) {
    return _asyncResult((index) {
      final cons = constraintsJson.toNativeUtf8();
      try {
        _pcCreateAnswer(pc, cons, _EventBus.resultCallable.nativeFunction,
            _EventBus.userDataFor(index));
      } finally {
        malloc.free(cons);
      }
    });
  }

  static Future<void> pcSetLocalDescription(
      Pointer<Void> pc, String sdp, String type) {
    return _asyncVoid((index) {
      final s = sdp.toNativeUtf8();
      final t = type.toNativeUtf8();
      try {
        _pcSetLocalDescription(pc, s, t, _EventBus.resultCallable.nativeFunction,
            _EventBus.userDataFor(index));
      } finally {
        malloc.free(s);
        malloc.free(t);
      }
    });
  }

  static Future<void> pcSetRemoteDescription(
      Pointer<Void> pc, String sdp, String type) {
    return _asyncVoid((index) {
      final s = sdp.toNativeUtf8();
      final t = type.toNativeUtf8();
      try {
        _pcSetRemoteDescription(pc, s, t,
            _EventBus.resultCallable.nativeFunction, _EventBus.userDataFor(index));
      } finally {
        malloc.free(s);
        malloc.free(t);
      }
    });
  }

  static int pcAddIceCandidate(Pointer<Void> pc, String candidateJson) {
    final c = candidateJson.toNativeUtf8();
    try {
      return _pcAddIceCandidate(pc, c);
    } finally {
      malloc.free(c);
    }
  }

  static Map<String, dynamic>? pcAddTrack(
      Pointer<Void> pc, String trackId, String? streamId) {
    final t = trackId.toNativeUtf8();
    final s = (streamId ?? '').toNativeUtf8();
    try {
      final ptr = _pcAddTrack(pc, t, s);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(t);
      malloc.free(s);
    }
  }

  static bool pcRemoveTrack(Pointer<Void> pc, String senderId) {
    final s = senderId.toNativeUtf8();
    try {
      final ptr = _pcRemoveTrack(pc, s);
      final json = _takeString(ptr);
      return json == null ? false : (_decode(json)['result'] as bool? ?? false);
    } finally {
      malloc.free(s);
    }
  }

  static List<dynamic> pcGetSenders(Pointer<Void> pc) {
    final ptr = _pcGetSenders(pc);
    final json = _takeString(ptr);
    return json == null ? const [] : _decode(json)['senders'] as List<dynamic>;
  }

  static List<dynamic> pcGetTransceivers(Pointer<Void> pc) {
    final ptr = _pcGetTransceivers(pc);
    final json = _takeString(ptr);
    return json == null
        ? const []
        : _decode(json)['transceivers'] as List<dynamic>;
  }

  static bool pcSenderSetParameters(
      Pointer<Void> pc, String senderId, String paramsJson) {
    final sid = senderId.toNativeUtf8();
    final p = paramsJson.toNativeUtf8();
    try {
      final ptr = _pcSenderSetParameters(pc, sid, p);
      final json = _takeString(ptr);
      return json == null ? false : (_decode(json)['result'] as bool? ?? false);
    } finally {
      malloc.free(sid);
      malloc.free(p);
    }
  }

  static void pcTransceiverSetCodecPreferences(
      Pointer<Void> pc, String transceiverId, String codecsJson) {
    final tid = transceiverId.toNativeUtf8();
    final c = codecsJson.toNativeUtf8();
    try {
      _pcTransceiverSetCodecPreferences(pc, tid, c);
    } finally {
      malloc.free(tid);
      malloc.free(c);
    }
  }

  static Future<List<dynamic>> pcGetStats(Pointer<Void> pc, String trackId) async {
    final json = await _asyncResult((index) {
      final t = trackId.toNativeUtf8();
      try {
        _pcGetStats(pc, t, _EventBus.resultCallable.nativeFunction,
            _EventBus.userDataFor(index));
      } finally {
        malloc.free(t);
      }
    });
    return (json['stats'] as List<dynamic>?) ?? const [];
  }

  // ---- getUserMedia / 设备 / 本地流 ----
  static Map<String, dynamic>? getUserMedia(
      Pointer<Void> factory, String mediaConstraintsJson) {
    final m = mediaConstraintsJson.toNativeUtf8();
    try {
      final ptr = _getUserMedia(factory, m);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(m);
    }
  }

  static void streamDispose(Pointer<Void> factory, String streamId) {
    final s = streamId.toNativeUtf8();
    try {
      _streamDispose(factory, s);
    } finally {
      malloc.free(s);
    }
  }

  static List<dynamic> getSources(Pointer<Void> factory) {
    final ptr = _getSources(factory);
    final json = _takeString(ptr);
    return json == null ? const [] : _decode(json)['sources'] as List<dynamic>;
  }

  static int selectAudioInput(Pointer<Void> factory, String deviceId) {
    final d = deviceId.toNativeUtf8();
    try {
      return _selectAudioInput(factory, d);
    } finally {
      malloc.free(d);
    }
  }

  static Map<String, dynamic>? createLocalMediaStream(Pointer<Void> factory) {
    final ptr = _createLocalMediaStream(factory);
    final json = _takeString(ptr);
    return json == null ? null : _decode(json);
  }

  static Map<String, dynamic>? mediaStreamGetTracks(
      Pointer<Void> factory, String streamId) {
    final s = streamId.toNativeUtf8();
    try {
      final ptr = _mediaStreamGetTracks(factory, s);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(s);
    }
  }

  static void mediaStreamDispose(Pointer<Void> factory, String streamId) {
    final s = streamId.toNativeUtf8();
    try {
      _mediaStreamDispose(factory, s);
    } finally {
      malloc.free(s);
    }
  }

  static void mediaStreamTrackDispose(Pointer<Void> factory, String trackId) {
    final t = trackId.toNativeUtf8();
    try {
      _mediaStreamTrackDispose(factory, t);
    } finally {
      malloc.free(t);
    }
  }

  static bool mediaStreamAddTrack(
      Pointer<Void> factory, String streamId, String trackId) {
    final s = streamId.toNativeUtf8();
    final t = trackId.toNativeUtf8();
    try {
      return _mediaStreamAddTrack(factory, s, t) == 0;
    } finally {
      malloc.free(s);
      malloc.free(t);
    }
  }

  static bool mediaStreamRemoveTrack(
      Pointer<Void> factory, String streamId, String trackId) {
    final s = streamId.toNativeUtf8();
    final t = trackId.toNativeUtf8();
    try {
      return _mediaStreamRemoveTrack(factory, s, t) == 0;
    } finally {
      malloc.free(s);
      malloc.free(t);
    }
  }

  // ---- 系统音频 ----
  static Map<String, dynamic>? getSysAudioMedia(
      Pointer<Void> factory, String paramsJson) {
    final p = paramsJson.toNativeUtf8();
    try {
      final ptr = _getSysAudioMedia(factory, p);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(p);
    }
  }

  static void releaseSysAudioMedia(Pointer<Void> factory, String streamId) {
    final s = streamId.toNativeUtf8();
    try {
      _releaseSysAudioMedia(factory, s);
    } finally {
      malloc.free(s);
    }
  }

  // ---- 屏幕采集 ----
  static List<dynamic> getDesktopSources(
      Pointer<Void> factory, String typesJson) {
    final t = typesJson.toNativeUtf8();
    try {
      final ptr = _getDesktopSources(factory, t);
      final json = _takeString(ptr);
      return json == null ? const [] : _decode(json)['sources'] as List<dynamic>;
    } finally {
      malloc.free(t);
    }
  }

  static Map<String, dynamic>? getDisplayMedia(
      Pointer<Void> factory, String constraintsJson) {
    final c = constraintsJson.toNativeUtf8();
    try {
      final ptr = _getDisplayMedia(factory, c);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(c);
    }
  }

  // ---- RTP capabilities ----
  static Map<String, dynamic>? factoryGetRtpSenderCapabilities(
      Pointer<Void> factory, String kind) {
    final k = kind.toNativeUtf8();
    try {
      final ptr = _factoryGetRtpSenderCaps(factory, k);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(k);
    }
  }

  static Map<String, dynamic>? factoryGetRtpReceiverCapabilities(
      Pointer<Void> factory, String kind) {
    final k = kind.toNativeUtf8();
    try {
      final ptr = _factoryGetRtpReceiverCaps(factory, k);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(k);
    }
  }

  // ---- 系统音频 PCM 录制 ----
  static int enableSysAudioPcmRecording(
      Pointer<Void> factory, bool enable, String filePath) {
    final f = filePath.toNativeUtf8();
    try {
      return _enableSysAudioPcm(factory, enable ? 1 : 0, f);
    } finally {
      malloc.free(f);
    }
  }

  // ---- data channel ----
  static Map<String, dynamic>? createDataChannel(
      Pointer<Void> pc, String label, String initJson) {
    final l = label.toNativeUtf8();
    final i = initJson.toNativeUtf8();
    try {
      final ptr = _createDataChannel(pc, l, i);
      final json = _takeString(ptr);
      return json == null ? null : _decode(json);
    } finally {
      malloc.free(l);
      malloc.free(i);
    }
  }

  static int dataChannelSetCallback(
      Pointer<Void> factory, String flutterId, int eventIndex) {
    final f = flutterId.toNativeUtf8();
    try {
      return _dataChannelSetCallback(factory, f,
          _EventBus.eventCallable.nativeFunction, _EventBus.userDataFor(eventIndex));
    } finally {
      malloc.free(f);
    }
  }

  static int dataChannelSend(
      Pointer<Void> factory, String flutterId, bool isBinary, Uint8List data) {
    final f = flutterId.toNativeUtf8();
    final ptr = malloc.allocate<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      return _dataChannelSend(
          factory, f, isBinary ? 1 : 0, ptr, data.length);
    } finally {
      malloc.free(f);
      malloc.free(ptr);
    }
  }

  static int dataChannelBufferedAmount(
      Pointer<Void> factory, String flutterId) {
    final f = flutterId.toNativeUtf8();
    try {
      final ptr = _dataChannelBufferedAmount(factory, f);
      final json = _takeString(ptr);
      return json == null ? 0 : ((_decode(json)['bufferedAmount'] as num?) ?? 0).toInt();
    } finally {
      malloc.free(f);
    }
  }

  static void dataChannelClose(Pointer<Void> factory, String flutterId) {
    final f = flutterId.toNativeUtf8();
    try {
      _dataChannelClose(factory, f);
    } finally {
      malloc.free(f);
    }
  }

  // ---- 事件总线入口 ----
  static int registerEventHandler(void Function(String json) handler) =>
      _EventBus.register(handler);
  static int reserveEventHandler() => _EventBus.reserve();
  static void bindEventHandler(int index, void Function(String json) handler) =>
      _EventBus.bind(index, handler);
  static void unregisterEventHandler(int index) => _EventBus.unregister(index);

  // ---- 异步结果封装 ----
  static Future<Map<String, dynamic>> _asyncResult(
      void Function(int index) invoke) {
    final completer = Completer<Map<String, dynamic>>();
    late int index;
    index = _EventBus.register((json) {
      _EventBus.unregister(index);
      try {
        final map = _decode(json);
        if ((map['err'] as int?) != 0) {
          completer.completeError(
              Exception(map['err'] ?? 'async call failed'));
        } else {
          completer.complete(map);
        }
      } catch (e) {
        completer.completeError(e);
      }
    });
    invoke(index);
    return completer.future;
  }

  static Future<void> _asyncVoid(void Function(int index) invoke) async {
    await _asyncResult(invoke);
  }

  static Map<String, dynamic> _decode(String json) {
    return (jsonDecode(json) as Map<String, dynamic>);
  }
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
