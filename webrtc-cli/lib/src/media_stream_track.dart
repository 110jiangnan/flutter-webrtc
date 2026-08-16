import 'package:webrtc_interface/webrtc_interface.dart';

import 'native/ffi/webrtc_c.dart';

/// 镜像 media_stream_track_impl.dart 的 MediaStreamTrackNative,
/// extends webrtc_interface.MediaStreamTrack, 签名完全一致。
class MediaStreamTrackFfi extends MediaStreamTrack {
  MediaStreamTrackFfi(this.trackId, this.trackLabel, this.trackKind,
      this._enabled,
      {this.settings = const {}, String? ownerTag})
      : _ownerTag = ownerTag ?? '';

  factory MediaStreamTrackFfi.fromMap(Map<dynamic, dynamic> map,
          {String? ownerTag}) =>
      MediaStreamTrackFfi(map['id'] as String, map['label'] as String? ?? '',
          map['kind'] as String? ?? '', map['enabled'] as bool? ?? true,
          settings: map['settings'] ?? {}, ownerTag: ownerTag);

  final String trackId;
  final String trackLabel;
  final String trackKind;
  final Map<Object?, Object?> settings;
  final String _ownerTag;

  bool _enabled;
  bool _muted = false;

  String get peerConnectionId => _ownerTag;

  @override
  String? get id => trackId;
  @override
  String? get label => trackLabel;
  @override
  String? get kind => trackKind;

  @override
  bool get enabled => _enabled;

  /// 参考 flutter 原生 mediaStreamTrackSetEnable 也是 NotImplemented,
  /// C ABI 侧同样未实现, 这里只同步本地状态。
  @override
  set enabled(bool value) {
    _enabled = value;
    if (kind == 'audio') {
      _muted = !value;
    }
  }

  @override
  bool? get muted => _muted;

  @override
  Map<String, dynamic> getSettings() =>
      settings.map((key, value) => MapEntry(key.toString(), value));

  @override
  Future<void> stop() async {
    WebrtcC.mediaStreamTrackDispose(WebrtcRuntime.instance.factory, trackId);
  }

  @override
  Future<void> dispose() => stop();

  @override
  String toString() =>
      'Track(id: $id, kind: $kind, label: $label, enabled: $enabled, muted: $muted)';
}
