// webrtc.cc — 顶层 C ABI 入口(对应 flutter_webrtc.cc 的 HandleMethodCall):
// 只做薄薄的参数转译, 具体逻辑都分派到各模块:
//   factory / 本地流管理 → WebrtcBase / WebrtcMediaStream
//   getUserMedia/设备     → WebrtcMediaStream
//   createPeer/answer/ICE/发送 → WebrtcPeerConnection

#include <cstdlib>
#include <cstring>

#include "webrtc.h"

#include "webrtc_base.h"
#include "webrtc_common.h"
#include "webrtc_data_channel.h"
#include "webrtc_frame_cryptor.h"
#include "webrtc_media_stream.h"
#include "webrtc_peerconnection.h"
#include "webrtc_screen_capture.h"
#include "webrtc_sys_audio_manager.h"

#include "rtc_rtp_capabilities.h"

using namespace webrtc;

static WebrtcBase* AsBase(webrtc_handle factory) {
  return static_cast<WebrtcBase*>(factory);
}

// 常驻屏幕采集对象(懒创建): 作为 MediaListObserver 存活才能收到桌源事件。
// 与 flutter 的 FlutterScreenCapture 常驻生命周期对齐。
static WebrtcScreenCapture* AsScreenCapture(WebrtcBase* base) {
  if (!base->screen_capture_)
    base->screen_capture_ = std::make_unique<WebrtcScreenCapture>(base);
  return base->screen_capture_.get();
}

// 常驻 E2EE 帧加密对象(懒创建): 跨调用保存 frame_cryptors_/key_providers_ 注册表。
static WebrtcFrameCryptor* AsFrameCryptor(WebrtcBase* base) {
  if (!base->frame_cryptor_)
    base->frame_cryptor_ = std::make_unique<WebrtcFrameCryptor>(base);
  return base->frame_cryptor_.get();
}

// 通用分发(模板,C++ 链接, 放 extern "C" 块外): 取常驻 FrameCryptor, 执行 fn, 返回 JSON 字符串
template <typename Fn>
static char* FrameCryptorCall(webrtc_handle factory, const char* json, Fn fn) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !json) return nullptr;
  std::string s = fn(*AsFrameCryptor(base), ParseJson(json));
  return s.empty() ? nullptr : StrDup(s);
}

// 参考 flutter_webrtc.cc 的 getRtpSenderCapabilities 序列化
static char* RtpCapabilitiesToJson(libwebrtc::RTCRtpCapabilities* caps) {
  JNode codecs;
  codecs.type = JNode::kArr;
  for (auto& codec : caps->codecs().std_vector()) {
    codecs.arr.push_back(MakeObj({
        {"mimeType", MakeStr(codec->mime_type().std_string())},
        {"clockRate", MakeNum(codec->clock_rate())},
        {"channels", MakeNum(codec->channels())},
        {"sdpFmtpLine", MakeStr(codec->sdp_fmtp_line().std_string())},
    }));
  }
  JNode result;
  result.type = JNode::kObj;
  result.obj.emplace_back("codecs", std::move(codecs));
  JNode header_extensions;
  header_extensions.type = JNode::kArr;
  result.obj.emplace_back("headerExtensions", std::move(header_extensions));
  JNode fec;
  fec.type = JNode::kArr;
  result.obj.emplace_back("fecMechanisms", std::move(fec));
  return StrDup(ToJson(result));
}

static bool MediaTypeFromKind(const char* kind, RTCMediaType* out) {
  if (!kind) return false;
  if (0 == strcmp(kind, "video")) { *out = RTCMediaType::VIDEO; return true; }
  if (0 == strcmp(kind, "audio")) { *out = RTCMediaType::AUDIO; return true; }
  return false;
}

extern "C" {

// ================= factory =================

webrtc_handle webrtc_factory_create(void) {
  WebrtcBase* base = new WebrtcBase();
  if (!base->Initialize()) {
    delete base;
    return nullptr;
  }
  return base;
}

void webrtc_factory_destroy(webrtc_handle factory) {
  delete static_cast<WebrtcBase*>(factory);
}

int webrtc_factory_set_event_cb(webrtc_handle factory, webrtc_event_cb cb,
                                void* user_data) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return -1;
  base->factory_event_cb_ = cb;
  base->factory_event_ud_ = user_data;
  WebrtcMediaStream(base).OnDeviceChange();
  return 0;
}

// ================= createPeerConnection =================

webrtc_handle webrtc_create_peer_connection(webrtc_handle factory,
                                            const char* configuration_json,
                                            const char* constraints_json,
                                            webrtc_event_cb on_event,
                                            void* user_data) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  WebrtcPeerConnection peer_connection(base);
  return peer_connection.Create(ParseJson(configuration_json),
                                ParseJson(constraints_json), on_event, user_data);
}

void webrtc_pc_destroy(webrtc_handle pc) { WebrtcPeerConnection::Dispose(pc); }

// ================= getUserMedia =================

char* webrtc_get_user_media(webrtc_handle factory,
                            const char* media_constraints_json) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  WebrtcMediaStream media_stream(base);
  std::string json = media_stream.GetUserMedia(ParseJson(media_constraints_json));
  return json.empty() ? nullptr : StrDup(json);
}

// ================= RTP capabilities(被控 setCodecPreferences 前查可用编码) =================

char* webrtc_factory_get_rtp_sender_capabilities(webrtc_handle factory,
                                                 const char* kind) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  RTCMediaType media_type;
  if (!MediaTypeFromKind(kind, &media_type)) return nullptr;
  scoped_refptr<RTCRtpCapabilities> caps =
      base->factory_->GetRtpSenderCapabilities(media_type);
  return caps ? RtpCapabilitiesToJson(caps.get()) : nullptr;
}

char* webrtc_factory_get_rtp_receiver_capabilities(webrtc_handle factory,
                                                   const char* kind) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  RTCMediaType media_type;
  if (!MediaTypeFromKind(kind, &media_type)) return nullptr;
  scoped_refptr<RTCRtpCapabilities> caps =
      base->factory_->GetRtpReceiverCapabilities(media_type);
  return caps ? RtpCapabilitiesToJson(caps.get()) : nullptr;
}

// ================= 被控: 设备/本地流/轨道管理 =================

char* webrtc_get_sources(webrtc_handle factory) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  return StrDup(WebrtcMediaStream(base).GetSources());
}

int webrtc_select_audio_input(webrtc_handle factory, const char* device_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !device_id) return -1;
  return WebrtcMediaStream(base).SelectAudioInput(device_id) ? 0 : -1;
}

int webrtc_select_audio_output(webrtc_handle factory, const char* device_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !device_id) return -1;
  return WebrtcMediaStream(base).SelectAudioOutput(device_id) ? 0 : -1;
}

char* webrtc_create_local_media_stream(webrtc_handle factory) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  std::string json = WebrtcMediaStream(base).CreateLocalMediaStream();
  return json.empty() ? nullptr : StrDup(json);
}

char* webrtc_media_stream_get_tracks(webrtc_handle factory,
                                     const char* stream_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !stream_id) return nullptr;
  std::string json = WebrtcMediaStream(base).MediaStreamGetTracks(stream_id);
  return json.empty() ? nullptr : StrDup(json);
}

void webrtc_stream_dispose(webrtc_handle factory, const char* stream_id) {
  // 等价 webrtc_media_stream_dispose(见 webrtc.h:110 注释); 该符号在头里声明但此前未实现/未导出。
  WebrtcBase* base = AsBase(factory);
  if (!base || !stream_id) return;
  WebrtcMediaStream(base).MediaStreamDispose(stream_id);
}

void webrtc_media_stream_dispose(webrtc_handle factory, const char* stream_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !stream_id) return;
  WebrtcMediaStream(base).MediaStreamDispose(stream_id);
}

void webrtc_media_stream_track_dispose(webrtc_handle factory,
                                       const char* track_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !track_id) return;
  WebrtcMediaStream(base).MediaStreamTrackDispose(track_id);
}

int webrtc_media_stream_track_set_enable(webrtc_handle factory,
                                         const char* track_id, int enabled) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !track_id) return -1;
  return WebrtcMediaStream(base).MediaStreamTrackSetEnable(track_id,
                                                           enabled != 0)
             ? 0
             : -1;
}

int webrtc_track_set_volume(webrtc_handle factory, const char* track_id,
                            double volume) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !track_id) return -1;
  return WebrtcMediaStream(base).MediaStreamTrackSetVolume(track_id, volume) ? 0
                                                                             : -1;
}

int webrtc_media_stream_add_track(webrtc_handle factory, const char* stream_id,
                                  const char* track_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !stream_id || !track_id) return -1;
  return WebrtcMediaStream(base).MediaStreamAddTrack(stream_id, track_id) ? 0 : -1;
}

int webrtc_media_stream_remove_track(webrtc_handle factory,
                                     const char* stream_id,
                                     const char* track_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !stream_id || !track_id) return -1;
  return WebrtcMediaStream(base).MediaStreamRemoveTrack(stream_id, track_id) ? 0 : -1;
}

// ================= 被控: peer connection answer 流程 =================

void webrtc_pc_close(webrtc_handle pc) { WebrtcPeerConnection::Close(pc); }

void webrtc_pc_create_answer(webrtc_handle pc, const char* constraints_json,
                             webrtc_result_cb cb, void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.CreateAnswer(ParseJson(constraints_json), pc, cb, user_data);
}

void webrtc_pc_create_offer(webrtc_handle pc, const char* constraints_json,
                            webrtc_result_cb cb, void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.CreateOffer(ParseJson(constraints_json), pc, cb, user_data);
}

void webrtc_pc_get_local_description(webrtc_handle pc, webrtc_result_cb cb,
                                     void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.GetLocalDescription(pc, cb, user_data);
}

void webrtc_pc_get_remote_description(webrtc_handle pc, webrtc_result_cb cb,
                                      void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.GetRemoteDescription(pc, cb, user_data);
}

void webrtc_pc_set_local_description(webrtc_handle pc, const char* sdp,
                                     const char* type, webrtc_result_cb cb,
                                     void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.SetLocalDescription(sdp, type, pc, cb, user_data);
}

void webrtc_pc_set_remote_description(webrtc_handle pc, const char* sdp,
                                      const char* type, webrtc_result_cb cb,
                                      void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.SetRemoteDescription(sdp, type, pc, cb, user_data);
}

int webrtc_pc_add_ice_candidate(webrtc_handle pc, const char* candidate_json) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.AddIceCandidate(pc, candidate_json);
}

// ================= 被控: 发送媒体 =================

char* webrtc_pc_add_track(webrtc_handle pc, const char* track_id,
                          const char* stream_id) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.AddTrack(pc, track_id, stream_id);
}

char* webrtc_pc_remove_track(webrtc_handle pc, const char* sender_id) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.RemoveTrack(pc, sender_id);
}

char* webrtc_pc_get_senders(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.GetSenders(pc);
}

char* webrtc_pc_get_transceivers(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.GetTransceivers(pc);
}

char* webrtc_pc_sender_set_parameters(webrtc_handle pc, const char* sender_id,
                                      const char* params_json) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.RtpSenderSetParameters(pc, sender_id, params_json);
}

void webrtc_pc_transceiver_set_codec_preferences(webrtc_handle pc,
                                                 const char* transceiver_id,
                                                 const char* codecs_json) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.RtpTransceiverSetCodecPreferences(pc, transceiver_id, codecs_json);
}

void webrtc_pc_get_stats(webrtc_handle pc, const char* track_id,
                         webrtc_result_cb cb, void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.GetStats(pc, track_id, cb, user_data);
}

// ================= 主控/发送方补充 =================

char* webrtc_pc_add_transceiver(webrtc_handle pc, const char* track_id,
                                const char* media_type, const char* init_json) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.AddTransceiver(pc, track_id, media_type, init_json);
}

char* webrtc_pc_get_receivers(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.GetReceivers(pc);
}

void webrtc_pc_sender_set_track(webrtc_handle pc, const char* sender_id,
                                const char* track_id, webrtc_result_cb cb,
                                void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.RtpSenderSetTrack(pc, sender_id, track_id, cb, user_data);
}

void webrtc_pc_sender_set_stream(webrtc_handle pc, const char* sender_id,
                                 const char* stream_ids_json,
                                 webrtc_result_cb cb, void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.RtpSenderSetStream(pc, sender_id, stream_ids_json, cb, user_data);
}

void webrtc_pc_transceiver_stop(webrtc_handle pc, const char* transceiver_id,
                                webrtc_result_cb cb, void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.RtpTransceiverStop(pc, transceiver_id, cb, user_data);
}

void webrtc_pc_transceiver_get_current_direction(webrtc_handle pc,
                                                 const char* transceiver_id,
                                                 webrtc_result_cb cb,
                                                 void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.RtpTransceiverGetCurrentDirection(pc, transceiver_id, cb, user_data);
}

void webrtc_pc_transceiver_set_direction(webrtc_handle pc,
                                         const char* transceiver_id,
                                         const char* direction,
                                         webrtc_result_cb cb, void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.RtpTransceiverSetDirection(pc, transceiver_id, direction, cb, user_data);
}

void webrtc_pc_set_configuration(webrtc_handle pc, const char* configuration_json,
                                 webrtc_result_cb cb, void* user_data) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.SetConfiguration(pc, configuration_json, cb, user_data);
}

// ================= 补充: 媒体流/ICE重启/DTMF/状态查询 =================

int webrtc_pc_add_stream(webrtc_handle pc, const char* stream_id) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.AddStream(pc, stream_id);
}

int webrtc_pc_remove_stream(webrtc_handle pc, const char* stream_id) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.RemoveStream(pc, stream_id);
}

void webrtc_pc_restart_ice(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  pc_.RestartIce(pc);
}

int webrtc_pc_sender_can_insert_dtmf(webrtc_handle pc, const char* sender_id) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.RtpSenderCanInsertDtmf(pc, sender_id);
}

int webrtc_pc_sender_insert_dtmf(webrtc_handle pc, const char* sender_id,
                                 const char* tones, int duration, int gap) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.RtpSenderInsertDtmf(pc, sender_id, tones, duration, gap);
}

char* webrtc_pc_get_signaling_state(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.GetSignalingState(pc);
}

char* webrtc_pc_get_ice_gathering_state(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.GetIceGatheringState(pc);
}

char* webrtc_pc_get_ice_connection_state(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.GetIceConnectionState(pc);
}

char* webrtc_pc_get_connection_state(webrtc_handle pc) {
  WebrtcPeerConnection pc_(nullptr);
  return pc_.GetConnectionState(pc);
}

// ================= 被控: 系统音频采集 =================

char* webrtc_get_sys_audio_media(webrtc_handle factory,
                                 const char* params_json) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;

  JNode params = ParseJson(params_json);
  std::string device_id = params.StrOf("deviceId");
  std::string stream_id = params.StrOf("streamId");
  bool enable_pcm = false;
  const JNode* pcm = params.Get("enablePcmRecording");
  if (pcm && pcm->type == JNode::kBool) enable_pcm = pcm->b;
  std::string pcm_path = params.StrOf("pcmFilePath");

  WebrtcSysAudioManager* mgr = WebrtcSysAudioManager::GetInstance();
  if (!mgr->IsInitialized() && !mgr->Initialize(base, device_id)) return nullptr;
  if (!mgr->StartCapture()) return nullptr;
  if (enable_pcm) mgr->EnablePcmRecording(true, pcm_path);

  std::string json = mgr->GetSysAudioMedia(base, stream_id);
  return json.empty() ? nullptr : StrDup(json);
}

void webrtc_release_sys_audio_media(webrtc_handle factory,
                                    const char* stream_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return;
  if (stream_id) WebrtcMediaStream(base).MediaStreamDispose(stream_id);
  WebrtcSysAudioManager::DestroyInstance();
}

// 开启/关闭 PCM 录制(参考 flutter_webrtc.cc EnableSysAudioPcmRecording, 含默认路径处理)
int webrtc_enable_sys_audio_pcm_recording(webrtc_handle factory, int enable,
                                          const char* file_path) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return -1;
  std::string fp = file_path ? file_path : "";
  if (fp.empty()) fp = "E:/sys_audio_.pcm";
  if (fp.find("E:/") != 0 && fp.find("E:\\") != 0) fp = "E:/" + fp;
  WebrtcSysAudioManager::GetInstance()->EnablePcmRecording(enable != 0, fp);
  return 0;
}

// ================= 被控: 屏幕采集 =================

char* webrtc_get_desktop_sources(webrtc_handle factory,
                                 const char* types_json) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  std::string json =
      AsScreenCapture(base)->GetDesktopSources(ParseJson(types_json));
  return json.empty() ? nullptr : StrDup(json);
}

char* webrtc_update_desktop_sources(webrtc_handle factory,
                                    const char* types_json) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  std::string json =
      AsScreenCapture(base)->UpdateDesktopSources(ParseJson(types_json));
  return json.empty() ? nullptr : StrDup(json);
}

char* webrtc_get_display_media(webrtc_handle factory,
                               const char* constraints_json) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return nullptr;
  std::string json =
      AsScreenCapture(base)->GetDisplayMedia(ParseJson(constraints_json));
  return json.empty() ? nullptr : StrDup(json);
}

// 挂/摘桌面采集外部帧回调(锁屏帧替换): callback_ptr=0 清除恢复桌面采集。
// 无采集器(getDisplayMedia 未启动)返回 -1, 成功返回 0。
int webrtc_set_external_frame_callback(webrtc_handle factory,
                                       int64_t callback_ptr,
                                       void* user_data) {
  WebrtcBase* base = AsBase(factory);
  if (!base) return -1;
  return AsScreenCapture(base)->SetExternalFrameCallback(callback_ptr,
                                                         user_data);
}

// ================= 被控: data channel =================

char* webrtc_create_data_channel(webrtc_handle pc, const char* label,
                                 const char* init_json) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->base || !label) return nullptr;
  std::string json = WebrtcDataChannel(h->base)
                         .Create(pc, label, ParseJson(init_json));
  return json.empty() ? nullptr : StrDup(json);
}

int webrtc_data_channel_set_callback(webrtc_handle factory,
                                     const char* flutter_id,
                                     webrtc_event_cb cb, void* user_data) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !flutter_id) return -1;
  return WebrtcDataChannel(base).SetCallback(flutter_id, cb, user_data);
}

int webrtc_data_channel_send(webrtc_handle factory, const char* flutter_id,
                             int is_binary, const uint8_t* data, int len) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !flutter_id) return -1;
  return WebrtcDataChannel(base).Send(flutter_id, is_binary, data, len);
}

char* webrtc_data_channel_buffered_amount(webrtc_handle factory,
                                          const char* flutter_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !flutter_id) return nullptr;
  std::string json = WebrtcDataChannel(base).BufferedAmount(flutter_id);
  return json.empty() ? nullptr : StrDup(json);
}

void webrtc_data_channel_close(webrtc_handle factory, const char* flutter_id) {
  WebrtcBase* base = AsBase(factory);
  if (!base || !flutter_id) return;
  WebrtcDataChannel(base).Close(flutter_id);
}

void webrtc_free_string(char* s) { free(s); }

// ================= E2EE 帧加密(FrameCryptor / KeyProvider) =================

char* webrtc_frame_cryptor_factory_create_frame_cryptor(
    webrtc_handle pc, const char* constraints_json) {
  auto* h = static_cast<PcHandle*>(pc);
  if (!h || !h->base || !h->pc || !constraints_json) return nullptr;
  std::string s = AsFrameCryptor(h->base)
                      ->FrameCryptorFactoryCreateFrameCryptor(
                          h->pc, ParseJson(constraints_json));
  return s.empty() ? nullptr : StrDup(s);
}
char* webrtc_frame_cryptor_set_key_index(webrtc_handle factory,
                                         const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.FrameCryptorSetKeyIndex(c);
  });
}
char* webrtc_frame_cryptor_get_key_index(webrtc_handle factory,
                                         const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.FrameCryptorGetKeyIndex(c);
  });
}
char* webrtc_frame_cryptor_set_enabled(webrtc_handle factory,
                                       const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.FrameCryptorSetEnabled(c);
  });
}
char* webrtc_frame_cryptor_get_enabled(webrtc_handle factory,
                                       const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.FrameCryptorGetEnabled(c);
  });
}
char* webrtc_frame_cryptor_dispose(webrtc_handle factory,
                                   const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.FrameCryptorDispose(c);
  });
}
char* webrtc_frame_cryptor_factory_create_key_provider(
    webrtc_handle factory, const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.FrameCryptorFactoryCreateKeyProvider(c);
  });
}
char* webrtc_key_provider_set_shared_key(webrtc_handle factory,
                                         const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderSetSharedKey(c);
  });
}
char* webrtc_key_provider_ratchet_shared_key(webrtc_handle factory,
                                             const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderRatchetSharedKey(c);
  });
}
char* webrtc_key_provider_export_shared_key(webrtc_handle factory,
                                            const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderExportSharedKey(c);
  });
}
char* webrtc_key_provider_set_key(webrtc_handle factory,
                                  const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderSetKey(c);
  });
}
char* webrtc_key_provider_ratchet_key(webrtc_handle factory,
                                      const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderRatchetKey(c);
  });
}
char* webrtc_key_provider_export_key(webrtc_handle factory,
                                     const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderExportKey(c);
  });
}
char* webrtc_key_provider_set_sif_trailer(webrtc_handle factory,
                                          const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderSetSifTrailer(c);
  });
}
char* webrtc_key_provider_dispose(webrtc_handle factory,
                                  const char* constraints_json) {
  return FrameCryptorCall(factory, constraints_json, [](WebrtcFrameCryptor& fc,
                                                        const JNode& c) {
    return fc.KeyProviderDispose(c);
  });
}

}  // extern "C"
