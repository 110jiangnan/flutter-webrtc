part of 'webrtc_c.dart';

/// FFI 桥 — 媒体/设备/本地流域。
/// 承载: factory 生命周期 + factory 事件回调 + getUserMedia/getDisplayMedia +
/// 设备枚举/选择 + 本地流/轨道管理 + 系统音频 + RTP capabilities。
class WebrtcCMedia {
  WebrtcCMedia._();

  static final DynamicLibrary _lib = loadWebrtcLibrary();

  static final _factoryCreate = _lib
      .lookupFunction<_FactoryCreateNative, _FactoryCreateNative>(
          'webrtc_factory_create');
  static final _factoryDestroy = _lib
      .lookupFunction<_FactoryDestroyNative, _FactoryDestroyDart>(
          'webrtc_factory_destroy');
  static final _factorySetEventCb = _lib.lookupFunction<
      _FactorySetEventCbNative,
      _FactorySetEventCbDart>('webrtc_factory_set_event_cb');
  static final _getUserMedia = _lib.lookupFunction<_GetUserMediaNative,
      _GetUserMediaNative>('webrtc_get_user_media');
  static final _streamDispose = _lib.lookupFunction<_StreamDisposeNative, _StreamDisposeDart>('webrtc_stream_dispose');
  static final _getSources = _lib
      .lookupFunction<_GetSourcesNative, _GetSourcesNative>('webrtc_get_sources');
  static final _selectAudioInput = _lib.lookupFunction<
      _SelectAudioInputNative, _SelectAudioInputDart>('webrtc_select_audio_input');
  static final _selectAudioOutput = _lib.lookupFunction<
      _SelectAudioOutputNative, _SelectAudioOutputDart>('webrtc_select_audio_output');
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
  static final _mediaStreamTrackSetEnable = _lib.lookupFunction<
      _MediaStreamTrackSetEnableNative,
      _MediaStreamTrackSetEnableDart>('webrtc_media_stream_track_set_enable');
  static final _mediaStreamAddTrack = _lib.lookupFunction<
      _MediaStreamAddTrackNative,
      _MediaStreamAddTrackDart>('webrtc_media_stream_add_track');
  static final _mediaStreamRemoveTrack = _lib.lookupFunction<
      _MediaStreamRemoveTrackNative,
      _MediaStreamRemoveTrackDart>('webrtc_media_stream_remove_track');
  static final _getSysAudioMedia = _lib.lookupFunction<_GetSysAudioMediaNative,
      _GetSysAudioMediaNative>('webrtc_get_sys_audio_media');
  static final _releaseSysAudioMedia = _lib.lookupFunction<
      _ReleaseSysAudioMediaNative,
      _ReleaseSysAudioMediaDart>('webrtc_release_sys_audio_media');
  static final _factoryGetRtpSenderCaps = _lib.lookupFunction<
      _FactoryGetRtpSenderCapsNative,
      _FactoryGetRtpSenderCapsNative>('webrtc_factory_get_rtp_sender_capabilities');
  static final _factoryGetRtpReceiverCaps = _lib.lookupFunction<
      _FactoryGetRtpReceiverCapsNative,
      _FactoryGetRtpReceiverCapsNative>('webrtc_factory_get_rtp_receiver_capabilities');
  static final _enableSysAudioPcm = _lib.lookupFunction<_EnableSysAudioPcmNative,
      _EnableSysAudioPcmDart>('webrtc_enable_sys_audio_pcm_recording');
  static final _trackSetVolume = _lib.lookupFunction<_TrackSetVolumeNative,
      _TrackSetVolumeDart>('webrtc_track_set_volume');
  static final _freeString = _lib
      .lookupFunction<_FreeStringNative, _FreeStringDart>('webrtc_free_string');

  static String? _takeString(Pointer<Utf8> ptr) =>
      takeStringFrom(ptr, _freeString);

  // ---- factory ----
  static Pointer<Void> factoryCreate() => _factoryCreate();
  static void factoryDestroy(Pointer<Void> factory) => _factoryDestroy(factory);
  static int factorySetEventCallback(Pointer<Void> factory, int eventIndex) {
    return _factorySetEventCb(factory, EventBus.eventCallable.nativeFunction,
        EventBus.userDataFor(eventIndex));
  }

  // ---- getUserMedia / 设备 / 本地流 ----
  static Map<String, dynamic>? getUserMedia(
      Pointer<Void> factory, String mediaConstraintsJson) {
    final m = mediaConstraintsJson.toNativeUtf8();
    try {
      final ptr = _getUserMedia(factory, m);
      final json = _takeString(ptr);
      return json == null ? null : decodeJson(json);
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
    return json == null ? const [] : decodeJson(json)['sources'] as List<dynamic>;
  }

  static int selectAudioInput(Pointer<Void> factory, String deviceId) {
    final d = deviceId.toNativeUtf8();
    try {
      return _selectAudioInput(factory, d);
    } finally {
      malloc.free(d);
    }
  }

  static int selectAudioOutput(Pointer<Void> factory, String deviceId) {
    final d = deviceId.toNativeUtf8();
    try {
      return _selectAudioOutput(factory, d);
    } finally {
      malloc.free(d);
    }
  }

  static Map<String, dynamic>? createLocalMediaStream(Pointer<Void> factory) {
    final ptr = _createLocalMediaStream(factory);
    final json = _takeString(ptr);
    return json == null ? null : decodeJson(json);
  }

  static Map<String, dynamic>? mediaStreamGetTracks(
      Pointer<Void> factory, String streamId) {
    final s = streamId.toNativeUtf8();
    try {
      final ptr = _mediaStreamGetTracks(factory, s);
      final json = _takeString(ptr);
      return json == null ? null : decodeJson(json);
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

  static bool mediaStreamTrackSetEnable(
      Pointer<Void> factory, String trackId, bool enabled) {
    final t = trackId.toNativeUtf8();
    try {
      return _mediaStreamTrackSetEnable(factory, t, enabled ? 1 : 0) == 0;
    } finally {
      malloc.free(t);
    }
  }

  static bool trackSetVolume(
      Pointer<Void> factory, String trackId, double volume) {
    final t = trackId.toNativeUtf8();
    try {
      return _trackSetVolume(factory, t, volume) == 0;
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
      return json == null ? null : decodeJson(json);
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

  static int enableSysAudioPcmRecording(
      Pointer<Void> factory, bool enable, String filePath) {
    final f = filePath.toNativeUtf8();
    try {
      return _enableSysAudioPcm(factory, enable ? 1 : 0, f);
    } finally {
      malloc.free(f);
    }
  }

  // ---- RTP capabilities ----
  static Map<String, dynamic>? factoryGetRtpSenderCapabilities(
      Pointer<Void> factory, String kind) {
    final k = kind.toNativeUtf8();
    try {
      final ptr = _factoryGetRtpSenderCaps(factory, k);
      final json = _takeString(ptr);
      return json == null ? null : decodeJson(json);
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
      return json == null ? null : decodeJson(json);
    } finally {
      malloc.free(k);
    }
  }
}
