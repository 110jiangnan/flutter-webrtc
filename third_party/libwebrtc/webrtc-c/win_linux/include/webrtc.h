/* webrtc.h — 给 Dart FFI 用的纯 C ABI。
 *
 * 设计原则(对齐 flutter-webrtc 的 dart API, 不做 libwebrtc 的"原样转译"):
 *   1. 只暴露不透明句柄 + 函数, 不暴露任何 C++ 类型/vtable;
 *   2. 配置、约束、事件、结果统一用 JSON 字符串跨边界, dart 侧直接
 *      json.decode/encode 对上;
 *   3. 方法名/返回值语义照搬 flutter-webrtc 的 createPeerConnection /
 *      getUserMedia, 这样 dart 包一层就有亲切感;
 *   4. 事件回调是异步线程(webrtc signaling 线程)触发的, dart 侧请用
 *      NativeCallable.listener 注册, 不要用 isolateLocal。
 */
#ifndef WEBRTC_H
#define WEBRTC_H

#include <stdint.h>

/* 导出宏: 编译本 DLL 时 WEBRTC_EXPORTS 由 CMake 定义, 其它场合为 dllimport */
#ifdef _WIN32
#ifdef WEBRTC_EXPORTS
#define WEBRTC_API __declspec(dllexport)
#else
#define WEBRTC_API __declspec(dllimport)
#endif
#else
#define WEBRTC_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* 不透明句柄: dart 侧只当 void* 持有, 不要解引用 */
typedef void* webrtc_handle;

/* 事件回调。event_json 格式(和 flutter-webrtc 的 peerConnectionEvent 对齐):
 *   {"type":"onIceCandidate","candidate":{"candidate":"...","sdpMid":"0","sdpMLineIndex":0}}
 *   {"type":"onIceConnectionStateChange","state":"connected"}
 *   {"type":"onConnectionStateChange","state":"failed"}
 * binary/binary_len: 仅 dataChannelReceiveMessage 二进制消息时非 NULL——此时 JSON 无 "data" 字段,
 * 原始字节由指针直传, Dart 侧在回调内复制。文本消息/状态事件传 NULL/0。
 * user_data 原样回传。
 */
typedef void (*webrtc_event_cb)(void* user_data, const char* event_json,
                                const uint8_t* binary, int binary_len);

/* 异步结果回调(createAnswer/setDescription/getStats 等):
 * err == 0 成功, json 为结果; err != 0 失败, json 为 nullptr */
typedef void (*webrtc_result_cb)(void* user_data, int err, const char* json);

/* ---- factory(全局初始化一次) ----
 * 内部就是 LibWebRTC::Initialize + CreateRTCPeerConnectionFactory。
 */
WEBRTC_API webrtc_handle webrtc_factory_create(void);   /* 失败返回 NULL */
WEBRTC_API void webrtc_factory_destroy(webrtc_handle factory);

/* 注册 factory 级事件回调(设备热插拔 onDeviceChange 等全局事件), 0 成功。
 * event_json: {"event":"onDeviceChange"} */
WEBRTC_API int webrtc_factory_set_event_cb(webrtc_handle factory,
                                           webrtc_event_cb cb,
                                           void* user_data);

/* ---- createPeerConnection(对应 dart: createPeerConnection) ----
 * configuration_json:
 *   {"iceServers":[{"urls":["stun:stun.l.google.com:19302",
 *                           "turn:turn.example.com:3478?transport=udp"],
 *                   "username":"user","credential":"pass"}]}
 *   (urls 支持字符串或数组; 目前每个 server 取第一个 url)
 * constraints_json: 预留, 先传 "{}"
 * on_event: 该 PC 的所有事件回调; user_data 原样回传。
 * 返回 PC 句柄; 失败返回 NULL。
 */
WEBRTC_API webrtc_handle webrtc_create_peer_connection(webrtc_handle factory,
                                            const char* configuration_json,
                                            const char* constraints_json,
                                            webrtc_event_cb on_event,
                                            void* user_data);
WEBRTC_API void webrtc_pc_destroy(webrtc_handle pc);

/* ---- getUserMedia(对应 dart: getUserMedia) ----
 * media_constraints_json:
 *   {"audio":true, "video":{"width":{"ideal":1280},"height":{"ideal":720},"frameRate":{"ideal":30}}}
 *   audio/video 可传 true 或约束对象(支持 sourceId/deviceId/width/height/frameRate,
 *   数值可以是 {ideal:n} 形式)
 * 返回 malloc 的 JSON(用完 webrtc_free_string 释放), 失败返回 NULL:
 *   {"streamId":"<uuid>",
 *    "audioTracks":[{"id":"..","label":"..","kind":"audio","enabled":true,
 *                    "settings":{"deviceId":"..","kind":"audioinput","autoGainControl":true,
 *                                "echoCancellation":true,"noiseSuppression":true,
 *                                "channelCount":1,"latency":0}}],
 *    "videoTracks":[{"id":"..","label":"..","kind":"video","enabled":true,
 *                    "settings":{"deviceId":"..","kind":"videoinput","width":1280,
 *                                "height":720,"frameRate":30}}]}
 * 创建的本地流由 wrapper 按 streamId 持有, 不用时 webrtc_stream_dispose 释放。
 */
WEBRTC_API char* webrtc_get_user_media(webrtc_handle factory,
                            const char* media_constraints_json);
WEBRTC_API void webrtc_stream_dispose(webrtc_handle factory, const char* stream_id);

/* ---- RTP capabilities(被控查可用编码, 配合 setCodecPreferences) ----
 * kind: "audio"|"video" → {"codecs":[{mimeType,clockRate,channels,sdpFmtpLine}],
 *                           "headerExtensions":[],"fecMechanisms":[]}, 失败 NULL
 */
WEBRTC_API char* webrtc_factory_get_rtp_sender_capabilities(
    webrtc_handle factory, const char* kind);
WEBRTC_API char* webrtc_factory_get_rtp_receiver_capabilities(
    webrtc_handle factory, const char* kind);

/* ---- 被控: 设备/本地流/轨道管理 ---- */
/* 枚举采集设备, 返回 {"sources":[...]} */
WEBRTC_API char* webrtc_get_sources(webrtc_handle factory);
/* 选择麦克风输入设备, 0 成功 */
WEBRTC_API int webrtc_select_audio_input(webrtc_handle factory,
                                         const char* device_id);
/* 选择播放设备, 0 成功 */
WEBRTC_API int webrtc_select_audio_output(webrtc_handle factory,
                                          const char* device_id);
/* 创建空本地流, 返回 {"streamId":uuid} */
WEBRTC_API char* webrtc_create_local_media_stream(webrtc_handle factory);
/* 取流内轨道 {"audioTracks":[...],"videoTracks":[...]} */
WEBRTC_API char* webrtc_media_stream_get_tracks(webrtc_handle factory,
                                                const char* stream_id);
/* 释放本地流(停采集), 等价 webrtc_stream_dispose 的完整版 */
WEBRTC_API void webrtc_media_stream_dispose(webrtc_handle factory,
                                            const char* stream_id);
/* 释放单个轨道(停采集) */
WEBRTC_API void webrtc_media_stream_track_dispose(webrtc_handle factory,
                                                  const char* track_id);
/* 开/关轨道(enabled), 0 成功 */
WEBRTC_API int webrtc_media_stream_track_set_enable(webrtc_handle factory,
                                                    const char* track_id,
                                                    int enabled);
/* 往流里加/移除轨道, 0 成功 */
WEBRTC_API int webrtc_media_stream_add_track(webrtc_handle factory,
                                             const char* stream_id,
                                             const char* track_id);
WEBRTC_API int webrtc_media_stream_remove_track(webrtc_handle factory,
                                                const char* stream_id,
                                                const char* track_id);

/* ---- 被控/主控: peer connection 协商流程 ---- */
/* 关闭连接(句柄仍有效) */
WEBRTC_API void webrtc_pc_close(webrtc_handle pc);
/* 异步 createOffer, 回调返回 {"sdp":"...","type":"offer"} */
WEBRTC_API void webrtc_pc_create_offer(webrtc_handle pc,
                                       const char* constraints_json,
                                       webrtc_result_cb cb, void* user_data);
/* 异步取本地/远端会话描述, 回调返回 {"sdp":"...","type":"..."} */
WEBRTC_API void webrtc_pc_get_local_description(webrtc_handle pc,
                                                webrtc_result_cb cb,
                                                void* user_data);
WEBRTC_API void webrtc_pc_get_remote_description(webrtc_handle pc,
                                                 webrtc_result_cb cb,
                                                 void* user_data);
/* 异步 createAnswer, 回调返回 {"sdp":"...","type":"answer"} */
WEBRTC_API void webrtc_pc_create_answer(webrtc_handle pc,
                                        const char* constraints_json,
                                        webrtc_result_cb cb, void* user_data);
/* 异步 setLocalDescription / setRemoteDescription, 成功回调 err==0 */
WEBRTC_API void webrtc_pc_set_local_description(webrtc_handle pc,
                                                const char* sdp,
                                                const char* type,
                                                webrtc_result_cb cb,
                                                void* user_data);
WEBRTC_API void webrtc_pc_set_remote_description(webrtc_handle pc,
                                                 const char* sdp,
                                                 const char* type,
                                                 webrtc_result_cb cb,
                                                 void* user_data);
/* candidate_json: {"candidate":"...","sdpMid":"0","sdpMLineIndex":0}, 0 成功 */
WEBRTC_API int webrtc_pc_add_ice_candidate(webrtc_handle pc,
                                           const char* candidate_json);

/* ---- 被控: 发送媒体 ---- */
/* 把本地轨 addTrack 到 pc, 返回 sender 的 JSON, 失败 NULL */
WEBRTC_API char* webrtc_pc_add_track(webrtc_handle pc, const char* track_id,
                                     const char* stream_id);
/* 按 senderId 移除发送轨道, 返回 {"result":bool} */
WEBRTC_API char* webrtc_pc_remove_track(webrtc_handle pc, const char* sender_id);
/* 返回 {"senders":[...]} / {"transceivers":[...]} */
WEBRTC_API char* webrtc_pc_get_senders(webrtc_handle pc);
WEBRTC_API char* webrtc_pc_get_transceivers(webrtc_handle pc);
/* 设置 sender 编码参数(码率/帧率), 返回 {"result":bool} */
WEBRTC_API char* webrtc_pc_sender_set_parameters(webrtc_handle pc,
                                                 const char* sender_id,
                                                 const char* params_json);
/* 设置 transceiver 编码偏好, codecs_json: [{"mimeType","clockRate","channels","sdpFmtpLine"}] */
WEBRTC_API void webrtc_pc_transceiver_set_codec_preferences(
    webrtc_handle pc, const char* transceiver_id, const char* codecs_json);
/* 异步取统计, 回调返回 {"stats":[...]} */
WEBRTC_API void webrtc_pc_get_stats(webrtc_handle pc, const char* track_id,
                                    webrtc_result_cb cb, void* user_data);

/* ---- 主控/发送方补充(参考 flutter_peerconnection.h, 对齐 dart webrtc_interface) ---- */
/* AddTransceiver: track 或 mediaType + transceiverInit(可选)。
 *   track_id 非空走 track 重载; mediaType "audio"|"video"; init_json: {"direction","streamIds","sendEncodings"}
 * 返回 transceiver 的 JSON(transceiverToMap), 失败 NULL */
WEBRTC_API char* webrtc_pc_add_transceiver(webrtc_handle pc,
                                           const char* track_id,
                                           const char* media_type,
                                           const char* init_json);
/* 返回 {"receivers":[...]}(receiverToMap) */
WEBRTC_API char* webrtc_pc_get_receivers(webrtc_handle pc);
/* 给 sender 设 track(替换画面/音频), 回调 err==0 成功 */
WEBRTC_API void webrtc_pc_sender_set_track(webrtc_handle pc,
                                           const char* sender_id,
                                           const char* track_id,
                                           webrtc_result_cb cb, void* user_data);
/* 给 sender 设 streamIds(空串分隔的列表), 回调 err==0 成功 */
WEBRTC_API void webrtc_pc_sender_set_stream(webrtc_handle pc,
                                            const char* sender_id,
                                            const char* stream_ids_json,
                                            webrtc_result_cb cb, void* user_data);
/* stop transceiver, 回调 err==0 成功 */
WEBRTC_API void webrtc_pc_transceiver_stop(webrtc_handle pc,
                                           const char* transceiver_id,
                                           webrtc_result_cb cb, void* user_data);
/* 取 transceiver 当前方向, 回调返回 {"result":"sendrecv"|...} */
WEBRTC_API void webrtc_pc_transceiver_get_current_direction(
    webrtc_handle pc, const char* transceiver_id, webrtc_result_cb cb,
    void* user_data);
/* 设置 transceiver 方向, 回调 err==0 成功 */
WEBRTC_API void webrtc_pc_transceiver_set_direction(
    webrtc_handle pc, const char* transceiver_id, const char* direction,
    webrtc_result_cb cb, void* user_data);
/* 设置 PC 配置(iceServers 等; 参考实现本身即 TODO, 仅成功返回), 回调 err==0 */
WEBRTC_API void webrtc_pc_set_configuration(webrtc_handle pc,
                                            const char* configuration_json,
                                            webrtc_result_cb cb,
                                            void* user_data);

/* ---- 补充: 媒体流/ICE重启/DTMF/状态查询(对齐 flutter_webrtc.cc) ---- */
/* 把本地流挂到/摘离 pc(stream_id 指向 createLocalMediaStream/getUserMedia 的流), 0 成功 */
WEBRTC_API int webrtc_pc_add_stream(webrtc_handle pc, const char* stream_id);
WEBRTC_API int webrtc_pc_remove_stream(webrtc_handle pc, const char* stream_id);
/* 重启 ICE (pc->RestartIce) */
WEBRTC_API void webrtc_pc_restart_ice(webrtc_handle pc);
/* DTMF: 按 senderId 询问能否插入 / 插入音调, 返回 1 成功 */
WEBRTC_API int webrtc_pc_sender_can_insert_dtmf(webrtc_handle pc,
                                                const char* sender_id);
WEBRTC_API int webrtc_pc_sender_insert_dtmf(webrtc_handle pc,
                                            const char* sender_id,
                                            const char* tones, int duration,
                                            int gap);
/* 设置音频轨道音量(0.0~1.0), 0 成功 */
WEBRTC_API int webrtc_track_set_volume(webrtc_handle factory,
                                       const char* track_id, double volume);
/* 状态同步查询 → {"state":"..."}, 失败 "" */
WEBRTC_API char* webrtc_pc_get_signaling_state(webrtc_handle pc);
WEBRTC_API char* webrtc_pc_get_ice_gathering_state(webrtc_handle pc);
WEBRTC_API char* webrtc_pc_get_ice_connection_state(webrtc_handle pc);
WEBRTC_API char* webrtc_pc_get_connection_state(webrtc_handle pc);

/* ---- E2EE 帧加密(对齐 flutter_frame_cryptor) ----
 * createFrameCryptor 以 pc 句柄为第一个参数(本 C ABI 以句柄传递 PC),
 * constraints_json: {"type":"sender|receiver","rtpSenderId"|"rtpReceiverId",
 *   "algorithm":0|1,"participantId","keyProviderId"}
 * → {"frameCryptorId":uuid}, 失败 ""。
 * 其余方法以 factory 句柄 + constraints_json 调用。
 * 所有 KeyProvider 的 key/ratchetSalt/sifTrailer 等字节数组用 JSON 数字数组表示。
 * 状态事件经 factory 事件回调上报: {"event":"frameCryptionStateChanged",...}
 */
WEBRTC_API char* webrtc_frame_cryptor_factory_create_frame_cryptor(
    webrtc_handle pc, const char* constraints_json);
WEBRTC_API char* webrtc_frame_cryptor_set_key_index(webrtc_handle factory,
                                                    const char* constraints_json);
WEBRTC_API char* webrtc_frame_cryptor_get_key_index(webrtc_handle factory,
                                                    const char* constraints_json);
WEBRTC_API char* webrtc_frame_cryptor_set_enabled(webrtc_handle factory,
                                                  const char* constraints_json);
WEBRTC_API char* webrtc_frame_cryptor_get_enabled(webrtc_handle factory,
                                                  const char* constraints_json);
WEBRTC_API char* webrtc_frame_cryptor_dispose(webrtc_handle factory,
                                              const char* constraints_json);
/* KeyProvider: 创建(从 keyProviderOptions, 支持 keyDerivationAlgorithm: 0=PBKDF2|1=HKDF)
 * → {"keyProviderId":uuid} */
WEBRTC_API char* webrtc_frame_cryptor_factory_create_key_provider(
    webrtc_handle factory, const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_set_shared_key(webrtc_handle factory,
                                                    const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_ratchet_shared_key(
    webrtc_handle factory, const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_export_shared_key(
    webrtc_handle factory, const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_set_key(webrtc_handle factory,
                                             const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_ratchet_key(webrtc_handle factory,
                                                 const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_export_key(webrtc_handle factory,
                                                const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_set_sif_trailer(webrtc_handle factory,
                                                     const char* constraints_json);
WEBRTC_API char* webrtc_key_provider_dispose(webrtc_handle factory,
                                             const char* constraints_json);

/* ---- data channel 包 E2EE(对齐 flutter_data_packet_cryptor) ----
 * 与 FrameCryptor(加密媒体轨)两套; 复用 FrameCryptor 创建的 KeyProvider。
 * create constraints_json: {"keyProviderId":uuid,"algorithm":0|1}
 *   → {"dataCryptorId":uuid}, 失败 ""。
 * dispose: {"dataCryptorId":uuid} → {"result":"success"}
 * encrypt: {"dataCryptorId":uuid,"participantId":str,"keyIndex":n,"data":[...]}
 *   → {"data":[...],"iv":[...],"keyIndex":n}
 * decrypt: {"dataCryptorId":uuid,"participantId":str,"keyIndex":n,
 *           "data":[...],"iv":[...]} → {"data":[...]}
 * 失败均返回 ""。 */
WEBRTC_API char* webrtc_data_packet_cryptor_create(
    webrtc_handle factory, const char* constraints_json);
WEBRTC_API char* webrtc_data_packet_cryptor_dispose(
    webrtc_handle factory, const char* constraints_json);
WEBRTC_API char* webrtc_data_packet_cryptor_encrypt(
    webrtc_handle factory, const char* constraints_json);
WEBRTC_API char* webrtc_data_packet_cryptor_decrypt(
    webrtc_handle factory, const char* constraints_json);

/* ---- 被控: 系统音频采集(扬声器 loopback) ----
 * params_json: {"deviceId":"","streamId":"","enablePcmRecording":false,"pcmFilePath":""}
 * 返回 {"streamId","ownerTag","audioTracks":[...],"videoTracks":[]}, 失败 NULL
 */
WEBRTC_API char* webrtc_get_sys_audio_media(webrtc_handle factory,
                                            const char* params_json);
/* 释放系统音频流(同时销毁单例) */
WEBRTC_API void webrtc_release_sys_audio_media(webrtc_handle factory,
                                               const char* stream_id);
/* 开启/关闭 PCM 文件录制, 0 成功 */
WEBRTC_API int webrtc_enable_sys_audio_pcm_recording(webrtc_handle factory,
                                                     int enable,
                                                     const char* file_path);

/* ---- 被控: 屏幕采集(getDisplayMedia / 桌面源) ----
 * types_json: ["screen","window"] → {"sources":[{id,name,type,thumbnailSize}]}, 失败 NULL
 */
WEBRTC_API char* webrtc_get_desktop_sources(webrtc_handle factory,
                                            const char* types_json);
/* 不强制重载的源列表刷新(桌源增删改名经 factory 事件回调上报), →
 * {"result":true}, 失败 NULL */
WEBRTC_API char* webrtc_update_desktop_sources(webrtc_handle factory,
                                               const char* types_json);
/* 请求/检查屏幕录制权限(对齐上游 requestCapturePermission, mac 专属语义)。
 * mac: 已授权返回 {"result":true}; 未授权弹系统授权框并返回用户选择。
 * win/linux: 桌面采集无需权限, 恒返回 {"result":true}。失败 NULL。 */
WEBRTC_API char* webrtc_request_capture_permission(webrtc_handle factory);
/* constraints_json:
 *   {"video":{"deviceId":{"exact":"<sourceId>"},"mandatory":{"frameRate":30},"cursor":"never"}}
 * → {"streamId","audioTracks":[],"videoTracks":[{id,label,kind,enabled}]}, 失败 NULL
 */
WEBRTC_API char* webrtc_get_display_media(webrtc_handle factory,
                                          const char* constraints_json);

/* 挂/摘桌面采集的外部帧回调(锁屏帧替换, MyDesk 自定义): 让 libwebrtc 的桌面采集
 * 循环改用外部提供的帧数据插入视频管线, 替代 GDI/DXGI 采集。
 *   callback_ptr: 原生函数指针地址(Rust DLL 的 secure_screen_external_frame), 传 0 清除
 *                 并恢复正常桌面采集; user_data 显式传非空时为所有网络采集器统一使用,
 *                 传 NULL 时按**每路采集器自身的源 id**(EnumDisplayDevicesW 序号)自动路由。
 *   回调签名与 libwebrtc ExternalFrameCallback 一致:
 *     int(*)(void* user_data, ExternalFrameConsumer consume, void* ud)
 *     consume: C++ 提供的消费函数, 原型
 *       void(*)(void* ud, const uint8_t* argb, int w, int h, int len)
 *     Rust 在持有帧锁时同步调用 consume(ud, argb, w, h, len), 数据指针锁内稳定;
 *     len 为实际字节数, C++ 侧不得按 w*h*4 反推(不假设生产者缓冲紧凑排布),
 *     C++ 直接转 I420 + OnFrame; 返回 1 表示已消费一帧, 0 表示暂无可采帧(应跳过)。
 *   多屏: 一次调用对**所有在跑的**桌面采集器生效, 每路 sourceId 一路 track、各取各屏;
 *   回调指针会被记住, 之后新建的采集器(GetDisplayMedia)自动带上(锁屏期间新开会话)。
 * 返回 0 成功; -1 参数非法(factory 为 NULL)或当前无任何在跑的桌面采集器。 */
WEBRTC_API int webrtc_set_external_frame_callback(webrtc_handle factory,
                                                  int64_t callback_ptr,
                                                  void* user_data);

/* ---- 被控: data channel(接收主控控制命令) ----
 * 主动创建, init_json: {"id":0,"ordered":true,"reliable":true,
 *   "maxRetransmits":-1,"negotiated":false,"protocol":"sctp"}
 * 返回 {"id","label","flutterId"}, 失败 NULL
 */
WEBRTC_API char* webrtc_create_data_channel(webrtc_handle pc, const char* label,
                                            const char* init_json);
/* 给 data channel 注册事件回调(消息/状态; 由 didOpenDataChannel 事件的 flutterId 指定) */
WEBRTC_API int webrtc_data_channel_set_callback(webrtc_handle factory,
                                                const char* flutter_id,
                                                webrtc_event_cb cb,
                                                void* user_data);
/* 发送: is_binary=0 文本 / 1 二进制 */
WEBRTC_API int webrtc_data_channel_send(webrtc_handle factory,
                                        const char* flutter_id, int is_binary,
                                        const uint8_t* data, int len);
/* 返回 {"bufferedAmount":n} */
WEBRTC_API char* webrtc_data_channel_buffered_amount(webrtc_handle factory,
                                                     const char* flutter_id);
/* 关闭并从注册表移除 */
WEBRTC_API void webrtc_data_channel_close(webrtc_handle factory,
                                          const char* flutter_id);

/* 释放 webrtc_get_user_media 等返回的 malloc 字符串 */
WEBRTC_API void webrtc_free_string(char* s);

#ifdef __cplusplus
}
#endif
#endif /* WEBRTC_H */
