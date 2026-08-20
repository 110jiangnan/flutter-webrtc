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
 * user_data 原样回传。
 */
typedef void (*webrtc_event_cb)(void* user_data, const char* event_json);

/* 异步结果回调(createAnswer/setDescription/getStats 等):
 * err == 0 成功, json 为结果; err != 0 失败, json 为 nullptr */
typedef void (*webrtc_result_cb)(void* user_data, int err, const char* json);

/* ---- factory(全局初始化一次) ----
 * 内部就是 LibWebRTC::Initialize + CreateRTCPeerConnectionFactory。
 */
WEBRTC_API webrtc_handle webrtc_factory_create(void);   /* 失败返回 NULL */
WEBRTC_API void webrtc_factory_destroy(webrtc_handle factory);

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
/* 往流里加/移除轨道, 0 成功 */
WEBRTC_API int webrtc_media_stream_add_track(webrtc_handle factory,
                                             const char* stream_id,
                                             const char* track_id);
WEBRTC_API int webrtc_media_stream_remove_track(webrtc_handle factory,
                                                const char* stream_id,
                                                const char* track_id);

/* ---- 被控: peer connection answer 流程 ---- */
/* 关闭连接(句柄仍有效) */
WEBRTC_API void webrtc_pc_close(webrtc_handle pc);
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
/* constraints_json:
 *   {"video":{"deviceId":{"exact":"<sourceId>"},"mandatory":{"frameRate":30},"cursor":"never"}}
 * → {"streamId","audioTracks":[],"videoTracks":[{id,label,kind,enabled}]}, 失败 NULL
 */
WEBRTC_API char* webrtc_get_display_media(webrtc_handle factory,
                                          const char* constraints_json);

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
