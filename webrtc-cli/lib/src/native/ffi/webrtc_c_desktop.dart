part of 'webrtc_c.dart';

/// FFI 桥 — 屏幕采集域。
/// 源列表枚举/刷新 + getDisplayMedia(把画面发布给主控)。
/// 帧渲染回调 / 缩略图像素属"渲染显示", 按需求排除(不在此文件)。
class WebrtcCDesktop {
  WebrtcCDesktop._();

  static final DynamicLibrary _lib = loadWebrtcLibrary('desktop');

  static final _getDesktopSources = _lib.lookupFunction<
      _GetDesktopSourcesNative,
      _GetDesktopSourcesNative>('webrtc_get_desktop_sources');
  static final _updateDesktopSources = _lib.lookupFunction<
      _GetDesktopSourcesNative,
      _GetDesktopSourcesNative>('webrtc_update_desktop_sources');
  static final _getDisplayMedia = _lib.lookupFunction<_GetDisplayMediaNative,
      _GetDisplayMediaNative>('webrtc_get_display_media');
  static final _setExternalFrameCallback = _lib.lookupFunction<
      _SetExternalFrameCallbackNative,
      _SetExternalFrameCallbackDart>('webrtc_set_external_frame_callback');
  static final _requestCapturePermission = _lib.lookupFunction<
      _CapturePermissionNative,
      _CapturePermissionNative>('webrtc_request_capture_permission');
  static final _freeString = _lib
      .lookupFunction<_FreeStringNative, _FreeStringDart>('webrtc_free_string');

  static String? _takeString(Pointer<Utf8> ptr) =>
      takeStringFrom(ptr, _freeString);

  static List<dynamic> getDesktopSources(
      Pointer<Void> factory, String typesJson) {
    final t = typesJson.toNativeUtf8();
    try {
      final ptr = _getDesktopSources(factory, t);
      final json = _takeString(ptr);
      return json == null ? const [] : decodeJson(json)['sources'] as List<dynamic>;
    } finally {
      malloc.free(t);
    }
  }

  static bool updateDesktopSources(Pointer<Void> factory, String typesJson) {
    final t = typesJson.toNativeUtf8();
    try {
      final ptr = _updateDesktopSources(factory, t);
      final json = _takeString(ptr);
      return json == null ? false : (decodeJson(json)['result'] as bool? ?? false);
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
      return json == null ? null : decodeJson(json);
    } finally {
      malloc.free(c);
    }
  }

  /// 挂/摘桌面采集外部帧回调(锁屏帧替换): [callbackAddress] 为原生函数指针地址
  /// (Rust 的 secure_screen_external_frame), 传 0 清除恢复桌面采集。
  /// 对**所有在跑的**桌面采集器生效; 每路采集器自动带各自的源序号(user_data),
  /// Rust 回调据此取对应屏幕的锁屏帧(多屏 sourceId ↔ 每屏一路)。
  /// 返回 0 成功; -1 未启动桌面采集(库侧无采集器, 上层可轮询重试)。
  static int setExternalFrameCallback(
      Pointer<Void> factory, int callbackAddress) {
    return _setExternalFrameCallback(factory, callbackAddress, nullptr);
  }

  /// 请求/检查屏幕录制权限(对齐上游 requestCapturePermission, mac 语义):
  /// 已授权返回 true; 未授权弹系统授权框并返回用户选择。win/linux 恒 true。
  static bool requestCapturePermission(Pointer<Void> factory) {
    final ptr = _requestCapturePermission(factory);
    final json = _takeString(ptr);
    return json == null ? false : (decodeJson(json)['result'] as bool?) ?? false;
  }
}
