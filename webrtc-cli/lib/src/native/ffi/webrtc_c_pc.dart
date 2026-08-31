part of 'webrtc_c.dart';

/// FFI 桥 — peerconnection 域。
/// 承载: createPeerConnection + PC 生命周期 + offer/answer/sdp + ICE +
/// sender/transceiver 管理 + getStats。
class WebrtcCPc {
  WebrtcCPc._();

  static final DynamicLibrary _lib = loadWebrtcLibrary('pc');

  static final _createPeerConnection = _lib.lookupFunction<
      _CreatePeerConnectionNative,
      _CreatePeerConnectionNative>('webrtc_create_peer_connection');
  static final _pcDestroy =
      _lib.lookupFunction<_PcDestroyNative, _PcDestroyDart>('webrtc_pc_destroy');
  static final _pcClose =
      _lib.lookupFunction<_PcCloseNative, _PcCloseDart>('webrtc_pc_close');
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
  static final _pcCreateOffer = _lib.lookupFunction<_PcCreateOfferNative, _PcCreateOfferDart>('webrtc_pc_create_offer');
  static final _pcGetLocalDescription = _lib.lookupFunction<_PcGetDescriptionNative, _PcGetDescriptionDart>('webrtc_pc_get_local_description');
  static final _pcGetRemoteDescription = _lib.lookupFunction<_PcGetDescriptionNative, _PcGetDescriptionDart>('webrtc_pc_get_remote_description');
  static final _pcAddTransceiver = _lib.lookupFunction<_PcAddTransceiverNative, _PcAddTransceiverNative>('webrtc_pc_add_transceiver');
  static final _pcGetReceivers = _lib.lookupFunction<_PcGetReceiversNative, _PcGetReceiversNative>('webrtc_pc_get_receivers');
  static final _pcSenderSetTrack = _lib.lookupFunction<_PcSenderSetTrackNative, _PcSenderSetTrackDart>('webrtc_pc_sender_set_track');
  static final _pcSenderSetStream = _lib.lookupFunction<_PcSenderSetStreamNative, _PcSenderSetStreamDart>('webrtc_pc_sender_set_stream');
  static final _pcTransceiverStop = _lib.lookupFunction<_PcTransceiverStopNative, _PcTransceiverStopDart>('webrtc_pc_transceiver_stop');
  static final _pcTransceiverGetCurrentDirection = _lib.lookupFunction<_PcTransceiverGetCurrentDirectionNative, _PcTransceiverGetCurrentDirectionDart>('webrtc_pc_transceiver_get_current_direction');
  static final _pcTransceiverSetDirection = _lib.lookupFunction<_PcTransceiverSetDirectionNative, _PcTransceiverSetDirectionDart>('webrtc_pc_transceiver_set_direction');
  static final _pcSetConfiguration = _lib.lookupFunction<_PcSetConfigurationNative, _PcSetConfigurationDart>('webrtc_pc_set_configuration');
  static final _pcAddStream = _lib.lookupFunction<_PcAddStreamNative, _PcAddStreamDart>('webrtc_pc_add_stream');
  static final _pcRemoveStream = _lib.lookupFunction<_PcRemoveStreamNative, _PcRemoveStreamDart>('webrtc_pc_remove_stream');
  static final _pcRestartIce = _lib.lookupFunction<_PcRestartIceNative, _PcRestartIceDart>('webrtc_pc_restart_ice');
  static final _pcSenderCanInsertDtmf = _lib.lookupFunction<_PcSenderCanInsertDtmfNative, _PcSenderCanInsertDtmfDart>('webrtc_pc_sender_can_insert_dtmf');
  static final _pcSenderInsertDtmf = _lib.lookupFunction<_PcSenderInsertDtmfNative, _PcSenderInsertDtmfDart>('webrtc_pc_sender_insert_dtmf');
  static final _pcGetSignalingState = _lib.lookupFunction<_PcGetStateNative, _PcGetStateNative>('webrtc_pc_get_signaling_state');
  static final _pcGetIceGatheringState = _lib.lookupFunction<_PcGetStateNative, _PcGetStateNative>('webrtc_pc_get_ice_gathering_state');
  static final _pcGetIceConnectionState = _lib.lookupFunction<_PcGetStateNative, _PcGetStateNative>('webrtc_pc_get_ice_connection_state');
  static final _pcGetConnectionState = _lib.lookupFunction<_PcGetStateNative, _PcGetStateNative>('webrtc_pc_get_connection_state');
  static final _freeString = _lib
      .lookupFunction<_FreeStringNative, _FreeStringDart>('webrtc_free_string');

  static String? _takeString(Pointer<Utf8> ptr) =>
      takeStringFrom(ptr, _freeString);

  // ---- createPeerConnection / PC ----
  static Pointer<Void> createPeerConnection(
      Pointer<Void> factory, String configurationJson, String constraintsJson,
      int eventIndex) {
    final cfg = configurationJson.toNativeUtf8();
    final cons = constraintsJson.toNativeUtf8();
    try {
      return _createPeerConnection(
          factory, cfg, cons, EventBus.eventCallable.nativeFunction,
          EventBus.userDataFor(eventIndex));
    } finally {
      malloc.free(cfg);
      malloc.free(cons);
    }
  }

  static void pcDestroy(Pointer<Void> pc) => _pcDestroy(pc);
  static void pcClose(Pointer<Void> pc) => _pcClose(pc);

  static Future<Map<String, dynamic>> pcCreateAnswer(
      Pointer<Void> pc, String constraintsJson) {
    return asyncResult((index) {
      final cons = constraintsJson.toNativeUtf8();
      try {
        _pcCreateAnswer(pc, cons, EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(cons);
      }
    });
  }

  static Future<void> pcSetLocalDescription(
      Pointer<Void> pc, String sdp, String type) {
    return asyncVoid((index) {
      final s = sdp.toNativeUtf8();
      final t = type.toNativeUtf8();
      try {
        _pcSetLocalDescription(pc, s, t, EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(s);
        malloc.free(t);
      }
    });
  }

  static Future<void> pcSetRemoteDescription(
      Pointer<Void> pc, String sdp, String type) {
    return asyncVoid((index) {
      final s = sdp.toNativeUtf8();
      final t = type.toNativeUtf8();
      try {
        _pcSetRemoteDescription(pc, s, t,
            EventBus.resultCallable.nativeFunction, EventBus.userDataFor(index));
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
      return json == null ? null : decodeJson(json);
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
      return json == null ? false : (decodeJson(json)['result'] as bool? ?? false);
    } finally {
      malloc.free(s);
    }
  }

  static List<dynamic> pcGetSenders(Pointer<Void> pc) {
    final ptr = _pcGetSenders(pc);
    final json = _takeString(ptr);
    return json == null ? const [] : decodeJson(json)['senders'] as List<dynamic>;
  }

  static List<dynamic> pcGetTransceivers(Pointer<Void> pc) {
    final ptr = _pcGetTransceivers(pc);
    final json = _takeString(ptr);
    return json == null
        ? const []
        : decodeJson(json)['transceivers'] as List<dynamic>;
  }

  static bool pcSenderSetParameters(
      Pointer<Void> pc, String senderId, String paramsJson) {
    final sid = senderId.toNativeUtf8();
    final p = paramsJson.toNativeUtf8();
    try {
      final ptr = _pcSenderSetParameters(pc, sid, p);
      final json = _takeString(ptr);
      return json == null ? false : (decodeJson(json)['result'] as bool? ?? false);
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
    final json = await asyncResult((index) {
      final t = trackId.toNativeUtf8();
      try {
        _pcGetStats(pc, t, EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(t);
      }
    });
    return (json['stats'] as List<dynamic>?) ?? const [];
  }

  static Future<Map<String, dynamic>> pcCreateOffer(
      Pointer<Void> pc, String constraintsJson) {
    return asyncResult((index) {
      final cons = constraintsJson.toNativeUtf8();
      try {
        _pcCreateOffer(pc, cons, EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(cons);
      }
    });
  }

  static Future<Map<String, dynamic>> pcGetLocalDescription(Pointer<Void> pc) {
    return asyncResult((index) => _pcGetLocalDescription(
        pc, EventBus.resultCallable.nativeFunction,
        EventBus.userDataFor(index)));
  }

  static Future<Map<String, dynamic>> pcGetRemoteDescription(
      Pointer<Void> pc) {
    return asyncResult((index) => _pcGetRemoteDescription(
        pc, EventBus.resultCallable.nativeFunction,
        EventBus.userDataFor(index)));
  }

  static Map<String, dynamic>? pcAddTransceiver(
      Pointer<Void> pc, String? trackId, String mediaType, String initJson) {
    final t = (trackId ?? '').toNativeUtf8();
    final m = mediaType.toNativeUtf8();
    final i = initJson.toNativeUtf8();
    try {
      final ptr = _pcAddTransceiver(pc, t, m, i);
      final json = _takeString(ptr);
      return json == null ? null : decodeJson(json);
    } finally {
      malloc.free(t);
      malloc.free(m);
      malloc.free(i);
    }
  }

  static List<dynamic> pcGetReceivers(Pointer<Void> pc) {
    final ptr = _pcGetReceivers(pc);
    final json = _takeString(ptr);
    return json == null
        ? const []
        : decodeJson(json)['receivers'] as List<dynamic>;
  }

  static Future<bool> pcSenderSetTrack(
      Pointer<Void> pc, String senderId, String? trackId) async {
    final json = await asyncResult((index) {
      final sid = senderId.toNativeUtf8();
      final t = (trackId ?? '').toNativeUtf8();
      try {
        _pcSenderSetTrack(pc, sid, t, EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(sid);
        malloc.free(t);
      }
    });
    return (json['err'] as int?) == 0;
  }

  static Future<bool> pcSenderSetStream(
      Pointer<Void> pc, String senderId, String streamIdsJson) async {
    final json = await asyncResult((index) {
      final sid = senderId.toNativeUtf8();
      final s = streamIdsJson.toNativeUtf8();
      try {
        _pcSenderSetStream(pc, sid, s,
            EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(sid);
        malloc.free(s);
      }
    });
    return (json['err'] as int?) == 0;
  }

  static Future<void> pcTransceiverStop(
      Pointer<Void> pc, String transceiverId) async {
    await asyncVoid((index) {
      final tid = transceiverId.toNativeUtf8();
      try {
        _pcTransceiverStop(pc, tid, EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(tid);
      }
    });
  }

  static Future<String> pcTransceiverGetCurrentDirection(
      Pointer<Void> pc, String transceiverId) async {
    final json = await asyncResult((index) {
      final tid = transceiverId.toNativeUtf8();
      try {
        _pcTransceiverGetCurrentDirection(pc, tid,
            EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(tid);
      }
    });
    return (json['result'] as String?) ?? '';
  }

  static Future<void> pcTransceiverSetDirection(
      Pointer<Void> pc, String transceiverId, String direction) async {
    await asyncVoid((index) {
      final tid = transceiverId.toNativeUtf8();
      final d = direction.toNativeUtf8();
      try {
        _pcTransceiverSetDirection(pc, tid, d,
            EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(tid);
        malloc.free(d);
      }
    });
  }

  static Future<void> pcSetConfiguration(
      Pointer<Void> pc, String configurationJson) async {
    await asyncVoid((index) {
      final c = configurationJson.toNativeUtf8();
      try {
        _pcSetConfiguration(pc, c, EventBus.resultCallable.nativeFunction,
            EventBus.userDataFor(index));
      } finally {
        malloc.free(c);
      }
    });
  }

  // ---- 媒体流 / ICE重启 / DTMF / 状态同步查询 ----
  static bool pcAddStream(Pointer<Void> pc, String streamId) {
    final s = streamId.toNativeUtf8();
    try {
      return _pcAddStream(pc, s) == 0;
    } finally {
      malloc.free(s);
    }
  }

  static bool pcRemoveStream(Pointer<Void> pc, String streamId) {
    final s = streamId.toNativeUtf8();
    try {
      return _pcRemoveStream(pc, s) == 0;
    } finally {
      malloc.free(s);
    }
  }

  static void pcRestartIce(Pointer<Void> pc) => _pcRestartIce(pc);

  static bool pcSenderCanInsertDtmf(Pointer<Void> pc, String senderId) {
    final s = senderId.toNativeUtf8();
    try {
      return _pcSenderCanInsertDtmf(pc, s) == 1;
    } finally {
      malloc.free(s);
    }
  }

  static bool pcSenderInsertDtmf(
      Pointer<Void> pc, String senderId, String tones, int duration, int gap) {
    final s = senderId.toNativeUtf8();
    final t = tones.toNativeUtf8();
    try {
      return _pcSenderInsertDtmf(pc, s, t, duration, gap) == 1;
    } finally {
      malloc.free(s);
      malloc.free(t);
    }
  }

  static String pcGetSignalingState(Pointer<Void> pc) =>
      _stateString(_pcGetSignalingState(pc));
  static String pcGetIceGatheringState(Pointer<Void> pc) =>
      _stateString(_pcGetIceGatheringState(pc));
  static String pcGetIceConnectionState(Pointer<Void> pc) =>
      _stateString(_pcGetIceConnectionState(pc));
  static String pcGetConnectionState(Pointer<Void> pc) =>
      _stateString(_pcGetConnectionState(pc));

  static String _stateString(Pointer<Utf8> ptr) {
    final json = _takeString(ptr);
    if (json == null || json.isEmpty) return '';
    return (decodeJson(json)['state'] as String?) ?? '';
  }
}
