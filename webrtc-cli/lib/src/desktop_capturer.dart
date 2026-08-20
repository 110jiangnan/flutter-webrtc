// ignore_for_file: constant_identifier_names  // 枚举名刻意对齐 flutter-webrtc
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'native/ffi/webrtc_c.dart';

/// 镜像 flutter-webrtc lib/src/desktop_capturer.dart 的源类型/接口。

enum SourceType { Screen, Window }

final desktopSourceTypeToString = <SourceType, String>{
  SourceType.Screen: 'screen',
  SourceType.Window: 'window',
};

final tringToDesktopSourceType = <String, SourceType>{
  'screen': SourceType.Screen,
  'window': SourceType.Window,
};

class ThumbnailSize {
  ThumbnailSize(this.width, this.height);
  factory ThumbnailSize.fromMap(Map<dynamic, dynamic> map) =>
      ThumbnailSize(map['width'], map['height']);
  int width;
  int height;

  Map<String, int> toMap() => {'width': width, 'height': height};
}

abstract class DesktopCapturerSource {
  String get id;
  String get name;
  Uint8List? get thumbnail;
  ThumbnailSize get thumbnailSize;
  SourceType get type;
  StreamController<String> get onNameChanged => throw UnimplementedError();
  StreamController<Uint8List> get onThumbnailChanged =>
      throw UnimplementedError();
}

abstract class DesktopCapturer {
  StreamController<DesktopCapturerSource> get onAdded =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onRemoved =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onNameChanged =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onThumbnailChanged =>
      throw UnimplementedError();

  Future<List<DesktopCapturerSource>> getSources(
      {required List<SourceType> types, ThumbnailSize? thumbnailSize});

  Future<bool> updateSources({required List<SourceType> types});

  Future<void> setExternalFrameCallback(int callbackAddress);
}

class DesktopCapturerSourceFfi implements DesktopCapturerSource {
  DesktopCapturerSourceFfi(this.id, this.name, this.type,
      {ThumbnailSize? thumbnailSize, this.thumbnail})
      : thumbnailSize = thumbnailSize ?? ThumbnailSize(0, 0);

  @override
  final String id;
  @override
  final String name;
  @override
  final SourceType type;
  @override
  Uint8List? thumbnail;
  @override
  ThumbnailSize thumbnailSize;

  final _nameChanged = StreamController<String>.broadcast();
  final _thumbnailChanged = StreamController<Uint8List>.broadcast();

  @override
  StreamController<String> get onNameChanged => _nameChanged;
  @override
  StreamController<Uint8List> get onThumbnailChanged => _thumbnailChanged;
}

class DesktopCapturerFfi implements DesktopCapturer {
  DesktopCapturerFfi._();
  static final DesktopCapturerFfi instance = DesktopCapturerFfi._();

  final _onAdded = StreamController<DesktopCapturerSource>.broadcast();
  final _onRemoved = StreamController<DesktopCapturerSource>.broadcast();
  final _onNameChanged = StreamController<DesktopCapturerSource>.broadcast();
  // 缩略图像素属"渲染显示", C ABI 未下发; 保持空 impl 占位
  final _onThumbnailChanged =
      StreamController<DesktopCapturerSource>.broadcast();

  @override
  StreamController<DesktopCapturerSource> get onAdded => _onAdded;
  @override
  StreamController<DesktopCapturerSource> get onRemoved => _onRemoved;
  @override
  StreamController<DesktopCapturerSource> get onNameChanged => _onNameChanged;
  @override
  StreamController<DesktopCapturerSource> get onThumbnailChanged =>
      _onThumbnailChanged;

  /// 由 factory 级事件回调路由进来(desktopSourceAdded/Removed/NameChanged)。
  void handleDesktopEvent(String event, Map<String, dynamic> map) {
    final source = DesktopCapturerSourceFfi(
        map['id'] as String? ?? '',
        map['name'] as String? ?? '',
        map['type'] == 'window' ? SourceType.Window : SourceType.Screen);
    switch (event) {
      case 'desktopSourceAdded':
        _onAdded.add(source);
        break;
      case 'desktopSourceRemoved':
        _onRemoved.add(source);
        break;
      case 'desktopSourceNameChanged':
        _onNameChanged.add(source);
        break;
    }
  }

  @override
  Future<List<DesktopCapturerSource>> getSources(
      {required List<SourceType> types, ThumbnailSize? thumbnailSize}) async {
    final typesList =
        types.map((e) => desktopSourceTypeToString[e]!).toList();
    final list = WebrtcC.getDesktopSources(
        WebrtcRuntime.instance.factory, jsonEncode(typesList));
    return list
        .map((e) => DesktopCapturerSourceFfi(
            e['id'] as String,
            e['name'] as String? ?? '',
            tringToDesktopSourceType[e['type'] as String] ??
                SourceType.Screen,
            thumbnailSize:
                ThumbnailSize((e['thumbnailSize']?['width'] as num?)?.toInt() ?? 0,
                    (e['thumbnailSize']?['height'] as num?)?.toInt() ?? 0)))
        .toList();
  }

  @override
  Future<bool> updateSources({required List<SourceType> types}) async {
    final typesList =
        types.map((e) => desktopSourceTypeToString[e]!).toList();
    return WebrtcC.updateDesktopSources(
        WebrtcRuntime.instance.factory, jsonEncode(typesList));
  }

  @override
  Future<void> setExternalFrameCallback(int callbackAddress) async {
    // 渲染相关(外部帧回调), 按需求排除
  }
}
