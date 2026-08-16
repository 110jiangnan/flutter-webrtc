/// webrtc_cli — WebRTC 桌面端(仅 PC)FFI 绑定库。
/// 类 extends webrtc_interface, 方法签名与 flutter-webrtc/lib/src 完全一致,
/// 可与 flutter_webrtc 在同一个项目里混用。
library;

export 'package:webrtc_interface/webrtc_interface.dart';

export 'src/desktop_capturer.dart';
export 'src/factory.dart';
export 'src/helper.dart';
export 'src/media_stream.dart';
export 'src/media_stream_track.dart';
export 'src/rtc_data_channel.dart';
export 'src/rtc_peerconnection.dart';
export 'src/rtc_rtp_receiver.dart';
export 'src/rtc_rtp_sender.dart';
export 'src/rtc_rtp_transceiver.dart';
export 'src/rtc_rtp_utils.dart';
export 'src/sys_audio_manager.dart';
