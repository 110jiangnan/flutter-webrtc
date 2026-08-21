part of 'webrtc_c.dart';

/// 底层 FFI 绑定的"基础定义 + 事件分发 + 库加载 + 公共辅助"。
/// 这是我们拆分 webrtc_c.dart 后的公共底座, 各功能文件(媒体/PC/数据通道/桌面)
/// 都共享本库作用域(part of), 直接用这里的 typedef/EventBus/辅助函数。

// ================= C 回调签名 =================
typedef EventCallbackNative = Void Function(
    Pointer<Void> userData, Pointer<Utf8> eventJson, Pointer<Uint8> binary, Int32 binaryLen);
typedef ResultCallbackNative = Void Function(
    Pointer<Void> userData, Int32 err, Pointer<Utf8> json);

// ================= C 函数签名(与 webrtc.h 一一对应) =================
typedef _FactoryCreateNative = Pointer<Void> Function();
typedef _FactoryDestroyNative = Void Function(Pointer<Void> factory);
typedef _FactorySetEventCbNative = Int32 Function(
    Pointer<Void> factory,
    Pointer<NativeFunction<EventCallbackNative>> cb,
    Pointer<Void> userData);
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
typedef _SelectAudioOutputNative = Int32 Function(
    Pointer<Void> factory, Pointer<Utf8> deviceId);
typedef _CreateLocalMediaStreamNative =
    Pointer<Utf8> Function(Pointer<Void> factory);
typedef _MediaStreamGetTracksNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _MediaStreamDisposeNative = Void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _MediaStreamTrackDisposeNative = Void Function(
    Pointer<Void> factory, Pointer<Utf8> trackId);
typedef _MediaStreamTrackSetEnableNative = Int32 Function(
    Pointer<Void> factory, Pointer<Utf8> trackId, Int32 enabled);
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
typedef _PcCreateOfferNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> constraintsJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcGetDescriptionNative = Void Function(
    Pointer<Void> pc,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcAddTransceiverNative = Pointer<Utf8> Function(
    Pointer<Void> pc, Pointer<Utf8> trackId, Pointer<Utf8> mediaType,
    Pointer<Utf8> initJson);
typedef _PcGetReceiversNative = Pointer<Utf8> Function(Pointer<Void> pc);
typedef _PcSenderSetTrackNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> senderId,
    Pointer<Utf8> trackId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSenderSetStreamNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> senderId,
    Pointer<Utf8> streamIdsJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcTransceiverStopNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> transceiverId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcTransceiverGetCurrentDirectionNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> transceiverId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcTransceiverSetDirectionNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> transceiverId,
    Pointer<Utf8> direction,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSetConfigurationNative = Void Function(
    Pointer<Void> pc,
    Pointer<Utf8> configurationJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcAddStreamNative = Int32 Function(
    Pointer<Void> pc, Pointer<Utf8> streamId);
typedef _PcRemoveStreamNative = Int32 Function(
    Pointer<Void> pc, Pointer<Utf8> streamId);
typedef _PcRestartIceNative = Void Function(Pointer<Void> pc);
typedef _PcSenderCanInsertDtmfNative = Int32 Function(
    Pointer<Void> pc, Pointer<Utf8> senderId);
typedef _PcSenderInsertDtmfNative = Int32 Function(
    Pointer<Void> pc, Pointer<Utf8> senderId, Pointer<Utf8> tones,
    Int32 duration, Int32 gap);
typedef _TrackSetVolumeNative = Int32 Function(
    Pointer<Void> factory, Pointer<Utf8> trackId, Double volume);
typedef _PcGetStateNative = Pointer<Utf8> Function(Pointer<Void> pc);

// FrameCryptor / KeyProvider: 统一签名 (factory, constraintsJson) → malloc JSON 字符串
typedef _FrameCryptorCallNative = Pointer<Utf8> Function(
    Pointer<Void> factory, Pointer<Utf8> constraintsJson);
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
typedef _SelectAudioOutputDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> deviceId);
typedef _MediaStreamAddTrackDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> streamId, Pointer<Utf8> trackId);
typedef _MediaStreamRemoveTrackDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> streamId, Pointer<Utf8> trackId);
typedef _MediaStreamTrackSetEnableDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> trackId, int enabled);
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
typedef _FactorySetEventCbDart = int Function(
    Pointer<Void> factory,
    Pointer<NativeFunction<EventCallbackNative>> cb,
    Pointer<Void> userData);

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
typedef _PcCreateOfferDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> constraintsJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcGetDescriptionDart = void Function(
    Pointer<Void> pc,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSenderSetTrackDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> senderId,
    Pointer<Utf8> trackId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSenderSetStreamDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> senderId,
    Pointer<Utf8> streamIdsJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcTransceiverStopDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> transceiverId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcTransceiverGetCurrentDirectionDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> transceiverId,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcTransceiverSetDirectionDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> transceiverId,
    Pointer<Utf8> direction,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcSetConfigurationDart = void Function(
    Pointer<Void> pc,
    Pointer<Utf8> configurationJson,
    Pointer<NativeFunction<ResultCallbackNative>> cb,
    Pointer<Void> userData);
typedef _PcAddStreamDart = int Function(
    Pointer<Void> pc, Pointer<Utf8> streamId);
typedef _PcRemoveStreamDart = int Function(
    Pointer<Void> pc, Pointer<Utf8> streamId);
typedef _PcRestartIceDart = void Function(Pointer<Void> pc);
typedef _PcSenderCanInsertDtmfDart = int Function(
    Pointer<Void> pc, Pointer<Utf8> senderId);
typedef _PcSenderInsertDtmfDart = int Function(
    Pointer<Void> pc, Pointer<Utf8> senderId, Pointer<Utf8> tones,
    int duration, int gap);
typedef _TrackSetVolumeDart = int Function(
    Pointer<Void> factory, Pointer<Utf8> trackId, double volume);
typedef _ReleaseSysAudioMediaDart = void Function(
    Pointer<Void> factory, Pointer<Utf8> streamId);
typedef _DataChannelCloseDart = void Function(
    Pointer<Void> factory, Pointer<Utf8> flutterId);
typedef _FreeStringDart = void Function(Pointer<Utf8> s);

// ================= 事件总线 =================

/// 事件处理器: json 为事件 JSON; binary 仅二进制数据通道消息非 null(原始字节已复制)。
typedef EventHandler = void Function(String json, Uint8List? binary);

/// 跨线程事件分发: 事件回调 → SendPort → 主 isolate → 按 index 路由到 handler。
class EventBus {
  static final ReceivePort _port = ReceivePort();
  static final Map<int, EventHandler> _handlers = {};
  static int _nextIndex = 1;

  // 事件回调(NativeCallable.listener, 可被任意线程调用)
  static void _onEvent(Pointer<Void> userData, Pointer<Utf8> eventJson,
      Pointer<Uint8> binary, int binaryLen) {
    final index = userData.address;
    final json = eventJson.toDartString();
    if (binary != nullptr && binaryLen > 0) {
      // 回调内复制原始字节, 之后 signaling 线程 buffer 即失效
      final bytes = Uint8List.fromList(binary.asTypedList(binaryLen));
      _port.sendPort.send([index, json, bytes]);
    } else {
      _port.sendPort.send([index, json]);
    }
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
        // 纯 JSON 事件
        handler(data[1] as String, null);
      } else if (data.length == 3 && data[1] is String) {
        // JSON + 二进制附件(dataChannelReceiveMessage)
        handler(data[1] as String, data[2] as Uint8List?);
      } else {
        // 异步结果: err, json
        final err = data[1] as int;
        final json = data[2] as String;
        handler(json.isEmpty ? '{"err":$err}' : json, null);
      }
    });
  }

  static int register(EventHandler handler) {
    final index = reserve();
    bind(index, handler);
    return index;
  }

  /// 先占一个索引(createPeerConnection 的 user_data 需要先于对象创建), 稍后 bind。
  static int reserve() {
    init();
    return _nextIndex++;
  }

  static void bind(int index, EventHandler handler) {
    _handlers[index] = handler;
  }

  static void unregister(int index) {
    _handlers.remove(index);
  }

  static Pointer<Void> userDataFor(int index) =>
      Pointer<Void>.fromAddress(index);
}

// ================= 库加载 =================

DynamicLibrary loadWebrtcLibrary() {
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
      r'E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c\cmake-build-debug\webrtc_c.dll',
      r'E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c\cmake-build-release\webrtc_c.dll',
    ],
    if (Platform.isMacOS) ...[
      'libwebrtc_c.dylib',
      'build/macos/Build/Products/Debug/webrtc_c/libwebrtc_c.dylib',
      'macos/runner/libwebrtc_c.dylib',
    ],
  ];
  for (final path in candidates) {
    try {
      // Windows: 先加载同目录的 libwebrtc.dll(webrtc_c.dll 依赖它, 加载器不搜 DLL 所在目录)
      // Mac: dlopen 会自动解析 dylib 同目录依赖, 无需手动 preload
      if (Platform.isWindows) {
        _preloadLibwebrtc(_dirOf(path));
      }
      return DynamicLibrary.open(path);
    } catch (_) {
      // 继续尝试
    }
  }
  throw StateError(
      Platform.isMacOS ? 'libwebrtc_c.dylib 加载失败' : 'webrtc_c.dll 加载失败'
      ', 可用环境变量 WEBRTC_C_LIB 指定路径');
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

// ================= 跨功能共享的辅助(原 WebrtcC 私有, 拆开后公开) =================

/// 释放每种功能各自的 DynamicLibrary 查找出的 free_string 符号。
/// 各功能类把各自 lookup 出的 webrtc_free_string 传进来。
String? takeStringFrom(Pointer<Utf8> ptr, void Function(Pointer<Utf8>) freeFn) {
  if (ptr == nullptr) return null;
  final s = ptr.toDartString();
  freeFn(ptr);
  return s;
}

Map<String, dynamic> decodeJson(String json) {
  return (jsonDecode(json) as Map<String, dynamic>);
}

/// 异步结果封装(注册一次性 handler, 收到回调即 unregister 并完成 future)。
Future<Map<String, dynamic>> asyncResult(void Function(int index) invoke) {
  final completer = Completer<Map<String, dynamic>>();
  late int index;
  index = EventBus.register((json, binary) {
    EventBus.unregister(index);
    try {
      final map = decodeJson(json);
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

Future<void> asyncVoid(void Function(int index) invoke) async {
  await asyncResult(invoke);
}
