part of 'webrtc_c.dart';

/// FFI 桥 — 屏幕采集域。
/// 源列表枚举/刷新 + getDisplayMedia(把画面发布给主控)。
/// 帧渲染回调 / 缩略图像素属"渲染显示", 按需求排除(不在此文件)。
class WebrtcCDesktop {
  WebrtcCDesktop._();

  static final DynamicLibrary _lib = loadWebrtcLibrary();

  static final _getDesktopSources = _lib.lookupFunction<
      _GetDesktopSourcesNative,
      _GetDesktopSourcesNative>('webrtc_get_desktop_sources');
  static final _updateDesktopSources = _lib.lookupFunction<
      _GetDesktopSourcesNative,
      _GetDesktopSourcesNative>('webrtc_update_desktop_sources');
  static final _getDisplayMedia = _lib.lookupFunction<_GetDisplayMediaNative,
      _GetDisplayMediaNative>('webrtc_get_display_media');
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
}
