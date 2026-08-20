# Windows/Linux 迁移方案（webrtc-cli / webrtc-c 路线）

本文件与 [macos迁移方案.md](./macos迁移方案.md) 配套，共同构成 webrtc-cli 三大平台的完整迁移地图。
**读顺序：先读本文档（win/linux 是 ABI 基准，dart 按它绑定），再看 macos迁移方案.md（mac 是独立另一套实现）。**

## 0. 一句话结论

- **win/linux** 用 `third_party/libwebrtc/webrtc-c/` 的一套 **C++** C ABI：直接封装 libwebrtc 的**内部 C++ API** 编译成 DLL/SO，dart 经 FFI 绑定这 38 个 `webrtc_*` 符号。
- **mac** **不复用** win/linux 这套 C++，在 `webrtc-c/mac/` 下另起独立 C ABI，照抄 `common/darwin` 的 **ObjC**(WebRTC.xcframework ObjC API) 剥掉 Flutter。
- 两平台导出**同名同签名**的 `webrtc_*`、**同样的 JSON 边界**，因此 dart 的 `webrtc_c.dart` 零改动（只换 dylib/so/dll 路径，以及 Windows 多一步 `_preloadLibwebrtc` 解析依赖 dll）。

> 与 flutter-webrtc 官方一致：win/linux 用 `common/cpp`（C++），mac/iOS 用 `common/darwin`（ObjC），**完全分离、互不引用**。mac 抄 darwin 的 ObjC，**不是** win/linux 的 C++。

## 1. 能力面与 ABI 基准（与 mac 对齐的 38 个符号）

win/linux 的 C ABI 是 **dart 绑定的基准**：顶层 `webrtc-c/include/webrtc.h` 声明全部 38 个 `webrtc_*` 函数，dart 的 `webrtc-cli/lib/src/native/ffi/webrtc_c.dart` 逐一定义绑定。**mac 的 `mac/include/webrtc.h` 就是从它照抄来的**，两者签名必须逐一对齐。

| 能力 | C ABI 函数 | 模块 |
|---|---|---|
| factory | `webrtc_factory_create/destroy` | `webrtc_base` |
| getUserMedia / 设备 | `webrtc_get_user_media`、`webrtc_get_sources`、`webrtc_select_audio_input` | `webrtc_media_stream` |
| 本地流管理 | `webrtc_create_local_media_stream`、`webrtc_media_stream_*`、`webrtc_stream_dispose` | `webrtc_media_stream` |
| PC / SDP / ICE | `webrtc_create_peer_connection`、`webrtc_pc_*` | `webrtc_peerconnection` |
| 发送媒体 / RTP cap | `webrtc_pc_add_track` 等 + `webrtc_factory_get_rtp_sender/receiver_capabilities` | `webrtc_peerconnection` |
| 数据通道 | `webrtc_create_data_channel`、`webrtc_data_channel_*` | `webrtc_data_channel` |
| 系统音频(loopback) | `webrtc_get_sys_audio_media` 等 | `webrtc_sys_audio_manager/source` + 平台采集器 |
| 屏幕采集 | `webrtc_get_desktop_sources`、`webrtc_get_display_media` | `webrtc_screen_capture` |

## 2. 目录结构（win/linux 原封不动，mac 在子目录独立）

```
third_party/libwebrtc/webrtc-c/
├── CMakeLists.txt       ← 按平台分支选择源文件(绝不无条件 set 某平台的文件)
├── common/              ← 三平台共用纯 std C++ 工具(JSON/日期/字符串等), 当前为空
│   ├── include/         ← common/include 已进 include 路径
│   └── README.md        ← 放置规则
├── win_linux/           ← win/linux 独有: C++ C ABI (封装 libwebrtc 内部 C++ API)
│   ├── include/         ← 顶层 C ABI 头(基准)
│   │   ├── webrtc.h     ← 38 个函数签名 + webrtc_handle/事件/结果回调 typedef
│   │   ├── webrtc_base.h / webrtc_common.h / webrtc_peerconnection.h
│   │   ├── webrtc_media_stream.h / webrtc_data_channel.h / webrtc_screen_capture.h
│   │   └── webrtc_sys_audio_manager.h / webrtc_sys_audio_source.h
│   │       webrtc_win_sys_audio_capturer.h / webrtc_linux_sys_audio_capturer.h
│   └── src/
│       ├── webrtc.cc          ← 顶层入口(对应 HandleMethodCall): 薄转译 + 分派
│       ├── webrtc_common.cc   ← JNode JSON 构建/访问器 + Fire 事件回调(win/linux 独有, 不进 common)
│       ├── webrtc_base.cc     ← factory/配置/工具
│       ├── webrtc_media_stream.cc  ← getUserMedia/设备/本地流
│       ├── webrtc_peerconnection.cc ← createPC/answer/ICE/发送/RTP cap
│       ├── webrtc_data_channel.cc
│       ├── webrtc_screen_capture.cc
│       ├── webrtc_sys_audio_manager.cc / webrtc_sys_audio_source.cc
│       ├── webrtc_win_sys_audio_capturer.cc   (仅 Windows: WASAPI loopback)
│       └── webrtc_linux_sys_audio_capturer.cc (仅 Linux: PulseAudio/PipeWire)
└── mac/                 ← mac 独立整套(见 macos迁移方案.md), 不在这里
```

## 3. 迁移规则（win/linux 视角）

1. **照抄 `common/cpp` 的 C++**，不是 darwin ObjC。`win_linux/` 的 `webrtc_*.cc` 是 `flutter_webrtc.cc`/`flutter_rtc_*` 的 C++ 版本，用 libwebrtc 内部 C++ API（`rtc_peerconnection_factory.h`、`rtc_media_stream_interface.h` 等）而非 ObjC。
2. **JSON 边界**：所有入参/出参走 JSON 字符串。`webrtc_common.cc` 的 `JNode` 负责组装，`ToJson` 输出；`Fire(event, body)` 组装 `{"event":"<name>", ...body}` 后 `cb_(ud, json)`。
3. **事件 key 是 `event`**，不是 `type`。`Fire()` 明确 `emplace_back("event", ...)`；事件名如 `onCandidate`/`onTrack`/`didOpenDataChannel`/`onAddStream`。dart 按 `event["event"]` 分派。（webrtc.h 顶部注释写 `type` 是过时注释，别照它写实现。）
4. **事件名与 mac(darwin) 不同属正常**：win/linux 用 `onCandidate`/`iceConnectionState` 等，mac 保留 darwin 的 `onIceCandidate`/`onConnectionStateChange` 等。**dart 端必须同时兼容两套名字**——如果要改，只应让一端的名字统一，而不是让 mac 照抄 win/linux 的 C++ 名。
5. **句柄语义**：`webrtc_handle` 即 void*。factory 句柄 = 单例工厂指针；PC 句柄 = RTCPeerConnection 指针（flutterId 为注册表 key）。mac 同样。
6. **平台采集器拆分**：系统音频采集与屏幕采集是平台强相关部分。win 用 WASAPI loopback，linux 用 PulseAudio/PipeWire，mac 用 ScreenCaptureKit（ObjC）。CMake 里按 `WIN32`/`Linux`/`APPLE` 分支选择源文件。
7. **导出宏**：`WEBRTC_API` 在 Windows 为 `__declspec(dllexport/dllimport)`，其它平台为 `__attribute__((visibility("default")))`；编译时 CMake 定义 `WEBRTC_EXPORTS`。
8. **Windows 特有**：`_preloadLibwebrtc` 用 dlopen 预载 `libwebrtc.dll`（libwebrtc_c.dll 依赖）；链接 `libwebrtc.dll.lib`、`ole32 mmdevapi`；POST_BUILD 把 `libwebrtc.dll` 拷到 webrtc_c.dll 旁边。这些全在 `if(WIN32)` 内，不影响 mac/linux。
9. **linux 特有**：`webrtc_linux_sys_audio_capturer.cc` 仅在 `CMAKE_SYSTEM_NAME=Linux` 追加；mac 在 `elseif(APPLE)` 分支换整套 ObjC 源。

## 4. CMake 基准（win/linux + mac 分支并存）

```cmake
set(WEBRTC_C_SOURCES "")          # 从空开始, 按平台分支追加, 绝不无条件 set
# common/ (纯 std C++ 工具): list(APPEND WEBRTC_C_SOURCES ${WEBRTC_COMMON_SOURCES})

if(WIN32 OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND WEBRTC_C_SOURCES
    win_linux/src/webrtc.cc win_linux/src/webrtc_common.cc win_linux/src/webrtc_base.cc
    win_linux/src/webrtc_media_stream.cc win_linux/src/webrtc_peerconnection.cc
    win_linux/src/webrtc_data_channel.cc win_linux/src/webrtc_screen_capture.cc
    win_linux/src/webrtc_sys_audio_manager.cc win_linux/src/webrtc_sys_audio_source.cc
    win_linux/src/webrtc_win_sys_audio_capturer.cc)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(APPEND WEBRTC_C_SOURCES win_linux/src/webrtc_linux_sys_audio_capturer.cc)
  endif()
elseif(APPLE)
  list(APPEND WEBRTC_C_SOURCES  mac/src/*.mm 整套)   # 见 macos迁移方案.md
endif()
```

> **关键纪律**：`win_linux/` 的 C++ 源**只有在 win/linux 分支才 set**；mac 分支绝不包含它们（mac 用的是 `mac/src` ObjC）。三平台共用的纯 std C++ 工具才进 `common/`（当前为空；`win_linux/webrtc_common.cc` 的 JNode 是 win/linux 独有，**不进 common**，因为 mac ObjC 用 NSJSONSerialization）。

## 5. dart FFI 改动（win/linux 已完成，dart 零改动是目标）

`webrtc_c.dart` 的 `_loadLibrary()` 按平台加载：
- Windows：`webrtc_c.dll` + `_preloadLibwebrtc()`（预载 `libwebrtc.dll`）
- Linux：`libwebrtc_c.so`
- macOS：`libwebrtc_c.dylib`（dlopen 自动解析同目录依赖，不需要 preload）

符号绑定三个平台**共用同一份**（同名同签名）→ 换平台只换加载路径/文件名。

## 6. 三平台迁移规则一览（看这一个表够了）

| 维度 | Windows | Linux | macOS |
|---|---|---|---|
| 目录 | `win_linux/`(C++ ABI) | 同左 | `mac/`(独立 ObjC) |
| 共享工具 | `common/`(三平台共用纯 std C++, 当前为空) | 同左 | 同左 |
| 照抄来源 | `common/cpp` C++ | 同左 | `common/darwin` ObjC |
| 依赖 API | libwebrtc 内部 C++ API | 同左 | WebRTC.xcframework ObjC API |
| 产物 | `webrtc_c.dll`(+`libwebrtc.dll`) | `libwebrtc_c.so` | `libwebrtc_c.dylib` |
| 系统音频采集 | WASAPI loopback | PulseAudio/PipeWire | ScreenCaptureKit(ObjC) |
| 屏幕采集 | C++ desktop capturer | 同左 | ObjC desktop capturer |
| 事件 key | `event` | `event` | `event` |
| 事件名 | `onCandidate`/`iceConnectionState`… | 同左 | darwin 名 `onIceCandidate`/`onConnectionStateChange`… |
| dart FFI | 已绑定 | 已绑定 | 零改动(换路径+去 preload) |
| 状态 | 已完成 | 已完成 | 源码已落地, 待 mac 编译验证(见 mac 文档 §9) |
