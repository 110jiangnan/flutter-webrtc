import 'package:webrtc_interface/webrtc_interface.dart';

/// C 侧 rtpParametersToMap 的 JSON → webrtc_interface.RTCRtpParameters。
RTCRtpParameters rtpParametersFromMap(Map<dynamic, dynamic> map) {
  final params = RTCRtpParameters();
  params.transactionId = map['transactionId'] as String?;
  final rtcp = map['rtcp'];
  if (rtcp is Map) {
    params.rtcp = RTCRTCPParameters(
        rtcp['cname'] as String? ?? '', rtcp['reducedSize'] as bool? ?? false);
  }
  params.headerExtensions = (map['headerExtensions'] as List<dynamic>? ?? [])
      .map((e) => RTCHeaderExtension.fromMap(e as Map<dynamic, dynamic>))
      .toList();
  params.encodings = (map['encodings'] as List<dynamic>? ?? [])
      .map((e) => RTCRtpEncoding.fromMap(e as Map<dynamic, dynamic>))
      .toList();
  params.codecs = (map['codecs'] as List<dynamic>? ?? [])
      .map((e) => RTCRTPCodec.fromMap(e as Map<dynamic, dynamic>))
      .toList();
  final deg = map['degradationPreference'];
  if (deg is String) {
    params.degradationPreference = degradationPreferenceforString(deg);
  }
  return params;
}

/// C 侧方向字符串 → 接口 TransceiverDirection(C 侧 kStopped 输出 "stoped")。
TransceiverDirection transceiverDirectionForString(String? s) {
  switch (s) {
    case 'sendrecv':
      return TransceiverDirection.SendRecv;
    case 'sendonly':
      return TransceiverDirection.SendOnly;
    case 'recvonly':
      return TransceiverDirection.RecvOnly;
    case 'stopped':
    case 'stoped':
      return TransceiverDirection.Stopped;
    case 'inactive':
      return TransceiverDirection.Inactive;
  }
  return TransceiverDirection.Inactive;
}
