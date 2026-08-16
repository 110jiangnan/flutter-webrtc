import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track.dart';
import 'native/ffi/webrtc_c.dart';

/// 镜像 media_stream_impl.dart 的 MediaStreamNative,
/// extends webrtc_interface.MediaStream, 签名完全一致。
class MediaStreamFfi extends MediaStream {
  MediaStreamFfi(super.streamId, super.ownerTag);

  factory MediaStreamFfi.fromMap(Map<dynamic, dynamic> map) =>
      MediaStreamFfi(map['streamId'] as String, map['ownerTag'] as String? ?? 'local')
        ..setMediaTracks(map['audioTracks'], map['videoTracks']);

  final List<MediaStreamTrack> _audioTracks = [];
  final List<MediaStreamTrack> _videoTracks = [];

  void setMediaTracks(List<dynamic>? audioTracks, List<dynamic>? videoTracks) {
    _audioTracks.clear();
    for (final track in audioTracks ?? const []) {
      _audioTracks.add(MediaStreamTrackFfi.fromMap(track, ownerTag: ownerTag));
    }
    _videoTracks.clear();
    for (final track in videoTracks ?? const []) {
      _videoTracks.add(MediaStreamTrackFfi.fromMap(track, ownerTag: ownerTag));
    }
  }

  @override
  bool? get active => true;

  @override
  @deprecated
  Future<void> getMediaTracks() async {
    final response =
        WebrtcC.mediaStreamGetTracks(WebrtcRuntime.instance.factory, id);
    if (response != null) {
      setMediaTracks(response['audioTracks'], response['videoTracks']);
    }
  }

  @override
  Future<void> addTrack(MediaStreamTrack track,
      {bool addToNative = true}) async {
    if (track.kind == 'audio') {
      _audioTracks.add(track);
    } else {
      _videoTracks.add(track);
    }
    if (addToNative) {
      WebrtcC.mediaStreamAddTrack(WebrtcRuntime.instance.factory, id, track.id!);
    }
  }

  @override
  Future<void> removeTrack(MediaStreamTrack track,
      {bool removeFromNative = true}) async {
    if (track.kind == 'audio') {
      _audioTracks.removeWhere((it) => it.id == track.id);
    } else {
      _videoTracks.removeWhere((it) => it.id == track.id);
    }
    if (removeFromNative) {
      WebrtcC.mediaStreamRemoveTrack(
          WebrtcRuntime.instance.factory, id, track.id!);
    }
  }

  @override
  List<MediaStreamTrack> getTracks() => <MediaStreamTrack>[
        ..._audioTracks,
        ..._videoTracks,
      ];

  @override
  List<MediaStreamTrack> getAudioTracks() => _audioTracks;

  @override
  List<MediaStreamTrack> getVideoTracks() => _videoTracks;

  @override
  Future<void> dispose() async {
    WebrtcC.mediaStreamDispose(WebrtcRuntime.instance.factory, id);
  }

  @override
  Future<MediaStream> clone() async {
    final response =
        WebrtcC.createLocalMediaStream(WebrtcRuntime.instance.factory);
    if (response == null) throw Exception('createLocalMediaStream failed');
    final cloneStream = MediaStreamFfi(response['streamId'] as String, id);
    for (final track in [..._audioTracks, ..._videoTracks]) {
      await cloneStream.addTrack(track);
    }
    return cloneStream;
  }
}
