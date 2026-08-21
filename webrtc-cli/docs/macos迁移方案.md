# MacOS 迁移方案（webrtc-cli / webrtc-c 路线）

> 配套文档：[windowslinux迁移方案.md](./windowslinux迁移方案.md)（win/linux 是 ABI 基准，dart 按它绑定）。三平台迁移规则总览见其 §6 表。

## 0. 一句话结论

webrtc-cli 是**纯 Dart FFI 项目**（无 Flutter 依赖），底层走 `third_party/libwebrtc/webrtc-c` 的 **C ABI**。
**mac 不复用 win/linux 的 webrtc-c C ABI**（那套 C++ 是 libwebrtc 内部 C++ API 的封装）。mac 在 `webrtc-c/mac/` 下另起一套**独立 C ABI**，但实现**照抄 `common/darwin` 的 ObjC 代码**（WebRTC.xcframework 的 ObjC API 封装），剥掉 Flutter 后包成与顶层 `webrtc.h` 完全一致的 `webrtc_*` 函数。

这与 flutter-webrtc 官方一致：win/linux 的 `common/cpp`（C++）与 mac/iOS 的 `common/darwin`（ObjC）是**完全分离**的两套，互不引用。mac 抄的是 darwin 的 ObjC，**不是** win/linux 的 C++。

## 1. webrtc-cli 现有功能面（以它为准，mac 只对齐这些）

从 `webrtc-cli/lib/src/native/ffi/webrtc_c.dart` 的 `lookupFunction` 提取，共 **79 个 `webrtc_*` 符号**（与 `mac/include/webrtc.h` 逐一对齐；早期文档记 38，任务 #17/#18/#19 补齐了 E2EE 帧加密与全部 PC 补充导出）：

| 能力 | C ABI 函数 | 对应 darwin ObjC 来源 |
|---|---|---|
| factory | `webrtc_factory_create/destroy/set_event_cb` | `FlutterWebRTCPlugin.m`：`initialize:` + 单例工厂 |
| getUserMedia | `webrtc_get_user_media`、`webrtc_get_sources`、`webrtc_select_audio_input/output` | `FlutterWebRTCPlugin.m`：`getUserMedia:/getSources:/selectAudioInput:` + `CameraUtils`/`LocalVideoTrack`/`LocalAudioTrack` |
| 本地流 | `webrtc_create_local_media_stream`、`webrtc_media_stream_*`(get_tracks/add_track/remove_track/track_dispose/dispose/track_set_enable)、`webrtc_track_set_volume`、`webrtc_stream_dispose` | `FlutterRTCMediaStream.m` |
| PC / SDP / ICE | `webrtc_create_peer_connection`、`webrtc_pc_destroy/close/create_offer/create_answer/get_local/remote_description/set_local/remote_description/add_ice_candidate/restart_ice/add_stream/remove_stream/set_configuration` | `FlutterRTCPeerConnection.m` |
| 发送媒体 | `webrtc_pc_add_track/remove_track/get_senders/get_transceivers/get_receivers/sender_set_parameters/sender_set_track/sender_set_stream/add_transceiver/transceiver_set_codec_preferences/transceiver_stop/transceiver_get_current_direction/transceiver_set_direction` | `FlutterRTCPeerConnection.m` |
| DTMF | `webrtc_pc_sender_can_insert_dtmf/insert_dtmf` | `FlutterRTCPeerConnection.m`（rtpSenderCanInsertDtmf/InsertDtmf） |
| 状态查询 | `webrtc_pc_get_signaling_state/get_ice_gathering_state/get_ice_connection_state/get_connection_state` | `FlutterRTCPeerConnection.m` |
| RTP cap | `webrtc_factory_get_rtp_sender/receiver_capabilities` | `FlutterRTCPeerConnection.m` |
| E2EE 帧加密 | `webrtc_frame_cryptor_factory_*`(create_frame_cryptor/create_key_provider)、`webrtc_frame_cryptor_*`(set/get_key_index、set/get_enabled、dispose)、`webrtc_key_provider_*`(set_shared_key、ratchet_shared_key、export_shared_key、set_key、ratchet_key、export_key、set_sif_trailer、dispose) | `FlutterWebRTCPlugin.m`（FrameCryptor 分类，见 §9，去 per-cryptor eventChannel 改走 factory 事件回调） |
| 数据通道 | `webrtc_create_data_channel`、`webrtc_data_channel_*`(set_callback/send/buffered_amount/close) | `FlutterRTCDataChannel.m` |
| **系统音频**(扬声器 loopback) | `webrtc_get_sys_audio_media`、`webrtc_release_sys_audio_media`、`webrtc_enable_sys_audio_pcm_recording` | `SysAudioCapturer.m`(ScreenCaptureKit) + `SysAudioTrackManager.m` |
| **屏幕采集** | `webrtc_get_desktop_sources`、`webrtc_update_desktop_sources`、`webrtc_get_display_media` | `FlutterRTCDesktopCapturer.m` |

> 不搬（webrtc-cli 不调、mac 不写）：录制器 recorder、视频渲染 renderer（webrtc-cli 无渲染，`videoRenderer()` 抛 UnimplementedError）。DataPacketCryptor 无 dart 消费，未搬。`handleMethodCall` 对应业务方法仍在 darwin 里，照抄时按需裁剪。

## 2. mac 不复用 webrtc-c 的 C ABI —— 各自独立

```text
win/linux :  webrtc-c/win_linux/ (C++ over libwebrtc C++ API) → DLL/SO
mac       :  webrtc-c/mac/ (ObjC over WebRTC.xcframework ObjC API) → dylib
共        :  webrtc-c/common/ (纯 std C++ 工具, 三个平台若共用才放, 当前为空)
```

两者都导出**同名同签名**的 `webrtc_*` C 函数、**同样的 JSON 边界**，因此 dart 侧 FFI 零改动（只换 `.dylib` 文件）。mac 的实现从 darwin ObjC 照抄，不是从 win/linux C++ 照抄。

## 3. 目录结构（mac/ 独立干净，文件不带 mac 前缀）

```
third_party/libwebrtc/webrtc-c/
├── common/                 ← 三平台共用纯 std C++ 工具, 当前为空 (含 include/)
├── win_linux/              ← win/linux 独有 C++ (见 windowslinux迁移方案.md, 不改)
└── mac/                     ← mac 独立整套（从 common/darwin 照抄）
    ├── include/
    │   └── webrtc.h         ← 照抄顶层 webrtc.h（79 个函数签名）
    └── src/
        ├── WebrtcPlugin.h / .mm
        │       ← 照抄 FlutterWebRTCPlugin.h/.m：单例 + peerConnections/localStreams/
        │          localTracks dict + mediaStreamToMap/mediaTrackToMap + 工厂初始化；
        │          去掉 Flutter 协议(FlutterPlugin/FlutterStreamHandler/FlutterMethodChannel/
        │          FlutterEventChannel/FlutterResult/FlutterEventSink)，换成 C ABI 回调
        ├── WebrtcRTCPeerConnection.h / .mm
        │       ← 照抄 FlutterRTCPeerConnection.h/.m（category: SDP/ICE/stats/senders/transceivers）
        ├── WebrtcRTCMediaStream.mm
        │       ← 照抄 FlutterRTCMediaStream.m（本地流/轨道增删取）
        ├── WebrtcRTCDataChannel.mm
        │       ← 照抄 FlutterRTCDataChannel.m（createDataChannel/send/close/bufferedAmount）
        ├── WebrtcRTCDesktopCapturer.mm
        │       ← 照抄 FlutterRTCDesktopCapturer.m（getDesktopSources/getDisplayMedia）
        ├── SysAudioCapturer.h / .mm   ← 照抄 SysAudioCapturer.m（ScreenCaptureKit 系统音频）
        ├── SysAudioTrackManager.mm    ← 照抄 SysAudioTrackManager.m
        ├── CameraUtils.mm             ← 照抄 CameraUtils.m
        ├── LocalVideoTrack.mm         ← 照抄 LocalVideoTrack.m
        └── LocalAudioTrack.mm         ← 照抄 LocalAudioTrack.m
```

## 4. Flutter → C ABI 的替换规则（去 Flutter 的核心）

照抄 darwin 时逐处替换，逻辑本体一行不动：

| darwin | mac C ABI |
|---|---|
| `handleMethodCall:` / `call.method` 字符串分发 | 各 `webrtc_*` C 函数直接调对应业务方法 |
| 参数 `call.arguments[@"x"]` | 从入参 JSON `json_decode` 出的 `NSDictionary` |
| `FlutterResult result`(异步块) | `webrtc_result_cb(user_data, err, json)`，包成 block 传进原 ObjC 方法 |
| `FlutterEventSink` / `FlutterEventChannel`（PC/dataChannel 事件流） | `webrtc_event_cb(user_data, event_json)`，存在 PC/DC 的 category 属性里 |
| `FlutterError` | err 非 0 + 错误字符串 |
| `postEvent(sink, dict)` | 把 dict 转 JSON 调 `webrtc_event_cb` |
| `FlutterWebRTCPlugin` → `WebrtcPlugin`（单例改名） | `+sharedInstance` |

**事件流改造**：darwin 里 `RTCPeerConnection (Flutter)` 的 `eventSink` 属性接收 delegate 事件；mac 里把它换成 `{webrtc_event_cb cb; void* user_data;}` 两个字段（或一个 `WebrtcEventCallback` 结构）。委托方法里原本 `postEvent(pc.eventSink, dict)` 的地方，改成调回调。事件 JSON 格式与顶层 webrtc.h 注释一致（`onIceCandidate`/`onIceConnectionStateChange`/`onConnectionStateChange`/`onTrack`/...）。

## 5. CMake（三平台按分支选源；win/linux 的 C++ 文件不进 mac 分支）

`webrtc-c/CMakeLists.txt` 从空源列表开始，只按平台分支追加。mac 分支用 ObjC 文件、.mm 用 OBJCXX 编译，链接 WebRTC.xcframework：

```cmake
# win/linux 分支(见 windowslinux迁移方案.md §4): 只在 WIN32/Linux 才 set win_linux/src
if(WIN32 OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND WEBRTC_C_SOURCES
    win_linux/src/webrtc.cc ... win_linux/src/webrtc_win_sys_audio_capturer.cc)
  ...(linux 加 webrtc_linux_sys_audio_capturer.cc)
elseif(APPLE)
  list(APPEND WEBRTC_C_SOURCES
    mac/src/WebrtcPlugin.mm
    mac/src/WebrtcRTCPeerConnection.mm
    mac/src/WebrtcRTCMediaStream.mm
    mac/src/WebrtcRTCDataChannel.mm
    mac/src/WebrtcRTCDesktopCapturer.mm
    mac/src/SysAudioCapturer.mm
    mac/src/SysAudioTrackManager.mm
    mac/src/CameraUtils.mm
    mac/src/LocalVideoTrack.mm
    mac/src/LocalAudioTrack.mm
    mac/src/VideoProcessingAdapter.mm
    mac/src/AudioProcessingAdapter.mm
    mac/src/AudioManager.mm)
  target_include_directories(webrtc_c PRIVATE mac/include mac/src)
  if(NOT WEBRTC_MAC_FRAMEWORK)
    set(WEBRTC_MAC_FRAMEWORK "${LIBWEBRTC_DIR}/WebRTC.xcframework/macos-arm64_x86_64/WebRTC.framework/WebRTC")
  endif()
  target_link_libraries(webrtc_c PRIVATE
    "${WEBRTC_MAC_FRAMEWORK}"
    "-framework CoreFoundation -framework Foundation"
    "-framework CoreAudio -framework AudioToolbox"
    "-framework AVFoundation -framework CoreMedia"
    "-framework CoreGraphics -framework CoreVideo"
    "-framework ScreenCaptureKit -framework AppKit")
  set_source_files_properties(
    mac/src/WebrtcPlugin.mm
    mac/src/WebrtcRTCPeerConnection.mm
    mac/src/WebrtcRTCMediaStream.mm
    mac/src/WebrtcRTCDataChannel.mm
    mac/src/WebrtcRTCDesktopCapturer.mm
    mac/src/SysAudioCapturer.mm
    mac/src/SysAudioTrackManager.mm
    mac/src/CameraUtils.mm
    mac/src/LocalVideoTrack.mm
    mac/src/LocalAudioTrack.mm
    mac/src/VideoProcessingAdapter.mm
    mac/src/AudioProcessingAdapter.mm
    mac/src/AudioManager.mm
    PROPERTIES LANGUAGE OBJCXX)
endif()
```

> 纪律：mac 分支**绝不包含** `win_linux/` 的任何 C++ 文件；`common/` 的纯 std C++ 工具(当前为空)才对三平台追加。

> 注意：`target_compile_definitions(webrtc_c PRIVATE RTC_DESKTOP_DEVICE)` 已全局加（桌面采集 vtable 对齐）。`LIB_WEBRTC_API_DLL`/`libwebrtc.dll.lib`/`ole32 mmdevapi`/POST_BUILD 拷 dll 都在 `if(WIN32)` 内，不影响 mac。

## 6. FFI 改动（dart 不动，只换 dylib）

`webrtc-cli/lib/src/native/ffi/webrtc_c.dart` 的 `_loadLibrary()`：
- `Platform.isMacOS` 时候选 `libwebrtc_c.dylib` / `build/macos/.../libwebrtc_c.dylib` / `macos/runner/libwebrtc_c.dylib`
- mac 的 `dlopen` 自动解析 dylib 同目录依赖，**不需要** Windows 的 `_preloadLibwebrtc`（收敛到 `Platform.isWindows` 分支）
- 符号绑定**不变**（mac C ABI 的 `webrtc_*` 与 win/linux 同名）→ dart 零改动

## 7. 落地顺序

1. `webrtc-c/mac/include/webrtc.h`：照抄顶层，79 个函数签名
2. `webrtc-c/mac/src/WebrtcPlugin.h/.mm`：单例中枢照抄去 Flutter + C ABI 桥（工厂/getUserMedia/createPC/getSources/selectAudioInput）
3. `WebrtcRTCPeerConnection.mm` / `WebrtcRTCMediaStream.mm` / `WebrtcRTCDataChannel.mm` / `WebrtcRTCDesktopCapturer.mm` / `SysAudioCapturer` / `SysAudioTrackManager` / `CameraUtils` / `Local*Track`
4. CMake Darwin 分支改 ObjC 源
5. 拿到 `WebRTC.xcframework` 后在 mac 机器 `cmake` 编出 `libwebrtc_c.dylib`
6. 跑通最小闭环（factory/流/SDP/ICE/数据通道）→ 验证系统音频采集（ScreenCaptureKit 抓扬声器）、屏幕采集

## 8. 风险与注意

- **xcframework 平台切片**：需 `macos-arm64_x86_64`（Universal）或与目标 mac CPU 匹配。
- **macOS 权限**：ScreenCaptureKit 系统音频 + 屏幕采集需"屏幕录制"权限（TCC），app 在 Info.plist 声明并请求；`content.displays.count == 0` 等失败分支已由 capturer 处理。
- **回调线程**：webrtc_event_cb 在 webrtc signaling 线程触发，dart 侧用 `NativeCallable.listener`（不要 isolateLocal），与顶层 webrtc.h 注释一致。
- **纯照抄，不新发明**：伪代码/缩略替换只在 Flutter 接线处发生；业务逻辑本体（factory 初始化、mediaStreamToMap、parseMediaConstraints、ScreenCaptureKit 采集）逐字节保留 darwin 实现。

## 9. 当前完成度（截至 2026-08-21，任务 #17/#18/#19 收尾）

**源码层已全部落地**（79 个 `webrtc_*` 符号、目录结构、CMake 全就位，未编过，遵守"不编译约束"）：

- `mac/include/webrtc.h`：照抄顶层，79 个签名。
- `mac/src/` 全部源文件已写（见 §3 目录树）：`WebrtcPlugin.{h,mm}`（单例中枢 + JSON/C 桥 + `extern "C"` 全部入口函数）、`WebrtcRTCPeerConnection.{h,mm}`、`WebrtcRTCDataChannel.{h,mm}`、`WebrtcRTCMediaStream.mm`、`WebrtcRTCDesktopCapturer.{h,mm}`、`WebrtcRTCFrameCryptor.mm`、`SysAudioCapturer.{h,mm}`、`SysAudioTrackManager.{h,mm}`、`CameraUtils.{h,mm}`、`LocalTrack.h`、`LocalVideoTrack.{h,mm}`、`LocalAudioTrack.{h,mm}`、`VideoProcessingAdapter.{h,mm}`、`AudioProcessingAdapter.{h,mm}`、`AudioManager.{h,mm}`、`RTCAudioSource+Private.h`、`media_stream_interface.h`。
- CMake Darwin 分支：全部 `.mm` 源 + OBJCXX 属性（含 `WebrtcRTCFrameCryptor.mm`，任务 #19 已加入源列表与属性列表）。

**任务 #17（C ABI 方法导出补齐）+ #18（ObjC 业务方法补齐）已完成（2026-08-21）：**
- `WebrtcPlugin.mm` 新增 25 个 `extern "C"` 导出：`webrtc_factory_set_event_cb`、`webrtc_pc_create_offer`、`webrtc_pc_get_local/remote_description`、`webrtc_pc_add_transceiver`、`webrtc_pc_get_receivers`、`webrtc_pc_sender_set_track/set_stream`、`webrtc_pc_transceiver_stop/get_current_direction/set_direction`、`webrtc_pc_set_configuration`、`webrtc_pc_add_stream/remove_stream`、`webrtc_pc_restart_ice`、`webrtc_pc_sender_can_insert_dtmf/insert_dtmf`、`webrtc_track_set_volume`、`webrtc_media_stream_track_set_enable`、`webrtc_select_audio_output`、`webrtc_update_desktop_sources`、4 个状态查询。
- 语义对齐：返回值契约照 win/linux C ABI 基线（`0 成功/-1 失败`、`"state"` 查询返回 `{"state":"..."}`）；业务逻辑照抄 darwin（DTMF ms→s、`currentDirection:` 出参、addStream/removeStream 走 `plugin.localStreams`）。
- `WebrtcRTCPeerConnection.{h,mm}` 新增 `peerConnectionGetLocalDescription:result:` / `peerConnectionGetRemoteDescription:result:`（照抄 darwin getLocalDescription/getRemoteDescription）。
- 已用脚本核对：header 声明与 mm 定义逐一对齐（79/79，无重复、无遗漏）。

**任务 #19（E2EE FrameCryptor）已完成（2026-08-20）：**
- `WebrtcRTCFrameCryptor.mm`：frameCryptor/keyProvider 全套业务方法（createFrameCryptor sender/receiver、set/getKeyIndex、set/getEnabled、dispose、createKeyProvider、set/ratchet/exportSharedKey、set/ratchet/exportKey、setSifTrailer、keyProviderDispose）。
- 与 darwin 的差异：pc 以句柄传参；字节数组（key/ratchetSalt/sifTrailer）在 C 边界是 JSON 数字数组（`WebrtcDataFromJsonArr`/`WebrtcJsonArrFromData`）；状态事件走 factory 级 `webrtc_event_cb`（`{"event":"frameCryptionStateChanged",...}`），不用 per-cryptor eventChannel。
- DataPacketCryptor 无 dart 消费，不搬。

**已核实的关键点（重开会话可直接信任）：**
- 79 个 `webrtc_*` 签名与 `mac/include/webrtc.h` 逐一对齐，dart 零改动。
- 事件包装 key 用 **`"event"`**（win/linux C++ `Fire()` 与 darwin 都实际用 `event`；webrtc.h 顶部注释写 `type` 是**过时**的，别被误导）。
- `webrtc_get_user_media` 用 `dispatch_semaphore` 同步等待 darwin 异步回调（依赖 FFI 线程 ≠ AppKit 主线程，否则会阻塞）。
- `getDesktopSources:` / `updateDesktopSources:` 实现是 `argsMap`（读 `@"types"`），C ABI 层传 `@{@"types": types}`。
- 摄像头辅助 selector（`findDeviceForPosition` 等）只在 `CameraUtils.mm` 定义一次，`WebrtcRTCMediaStream.mm` 仅调用，无重复。
- `selectAudioInput:/selectAudioOutput:` 业务方法在 `WebrtcRTCMediaStream.mm` 实现（桌面走 RTCAudioDeviceModule），`WebrtcPlugin.h` 仅声明。

**下一步（在 mac 机器上，需要 WebRTC.xcframework）→ 即 §7 第 5-6 步：**
1. 跑 `cmake` 编出 `libwebrtc_c.dylib`（`-DWEBRTC_MAC_FRAMEWORK=` 指向 xcframework 切片）。
2. 跑通最小闭环（factory/流/SDP/ICE/数据通道）。
3. 验证系统音频采集（ScreenCaptureKit 抓扬声器）与屏幕采集（TCC 屏幕录制权限）。
4. 若编译报错，按 §8 风险 + `webrtc-c/mac/src` 各文件与 darwin 原文逐字节比对定位（均为源码问题，不涉及 dart 侧）。
