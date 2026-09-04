# webrtc-c 同步上游 75 提交差距清单

> 分支 `zjn_1.6.1` 合并上游 flutter-webrtc 最新 ~75 个提交(`origin/zjn..zjn_1.6.1`, 2026-08 合入)。
> 本文件记录: 上游改了哪些 **webrtc-c 的照抄源头**(`common/cpp/`、`common/darwin/`、`windows/`、`linux/`),
> 我们的 `third_party/libwebrtc/webrtc-c/` 对应要跟什么。
> 定位: **差距清单 + 落地进度**(2026-09-04 已按 A 路线照抄落地一批, 见 §落地记录)。
> 前置事实: `webrtc-c/` 目录本身在这 75 提交中 **零改动**(独立子树); libwebrtc 头/库(`third_party/libwebrtc/include`、`lib`) 也是我们自维护, 上游 m150 升级需自行跟随, 不在本清单同步范围。

## 落地记录(2026-09-04)

已按"文件/方法/命名与上游一致"原则落地, 来源依据见下各节:

| webrtc-c 文件 | 改了什么 | 对应上游 |
|---|---|---|
| `common/flutter_utf8_sanitize.{h,cc}` 新增 | `SanitizeUtf8ForFlutter()` 原样照抄 | `common/cpp/src/flutter_utf8_sanitize.{h,cc}` + `e815ac2` |
| `common/loopback_capturer.h` 新增 | `LoopbackCapturer` 接口 + `CreateLoopbackCapturer` 声明原样照抄 | `common/cpp/include/loopback_capturer.h` |
| `win_linux/include/application_loopback_capturer.h` + `win_linux/src/application_loopback_capturer.cc` 新增 | `ApplicationLoopbackCapturer`(WASAPI ApplicationLoopbackAudio) 原样照抄 | `windows/application_loopback_capturer.{h,cc}` + `f3bccbc` |
| `win_linux/src/loopback_capturer_factory.cc` 新增(WIN32) | `CreateLoopbackCapturer(source_id)`(HWND→PID) 原样照抄 | `windows/loopback_capturer_factory.cc` |
| `win_linux/src/loopback_capturer_factory_linux.cc` 新增(Linux) | nullptr stub(无 libpulse 分支的等价物) | `linux/loopback_capturer_factory.cc`(no-libpulse 分支) |
| `win_linux/src/webrtc_screen_capture.cc/.h` | 3 处桌面源 name 套 `SanitizeUtf8ForFlutter`; cursor 约束扩为 always/never+bool; GetDisplayMedia 加 audio 约束分支(带出系统音频轨, loopback 采集); 加 `StopLoopback()`(GetDisplayMedia 开头 + 析构兜底) | `e815ac2` `e4053e8` `f3bccbc` |
| `win_linux/src/webrtc_base.cc/.h` + `webrtc_media_stream.cc` | `WebrtcBase::StopScreenLoopback()` 转发 + `MediaStreamDispose` 释放桌面采集器后调用 → 共享结束即停 loopback(等效上游 DesktopCapturerObserver::OnStop 语义, 我们无该 observer) | 上游 `FlutterScreenCapture::OnStop` |
| `win_linux/CMakeLists` | common/flutter_utf8_sanitize.cc + win_linux/application_loopback_capturer.cc + loopback_capturer_factory.cc + linux stub 编入 | — |
| `mac/src/WebrtcRTCDataChannel.mm` | eventQueue/webrtcEventCallback 并发访问加 `@synchronized(channel)` 保护 | `common/darwin/Classes/FlutterRTCDataChannel.m` |
| `include/rtc_data_packet_cryptor.h` + `win_linux/{include,src}/webrtc_data_packet_cryptor.{h,cc}` 新增 | `RTCDataPacketCryptor`/`EncryptedPacket` 头 + `WebrtcDataPacketCryptor`(create/dispose/encrypt/decrypt) 照抄 | `common/cpp/.../flutter_data_packet_cryptor.*` |
| `webrtc_frame_cryptor.{h,cc}` + `webrtc_base.{h,cc}` | 加 `GetKeyProviderForId`; base 加 `data_packet_cryptor_` 成员/析构 | 上游 `base_->key_providers_` |
| `webrtc.h`/`webrtc.cc` | 加 `webrtc_data_packet_cryptor_{create,dispose,encrypt,decrypt}` C ABI | — |
| `webrtc-cli/lib/.../webrtc_c_datapacketcryptor.dart` + `webrtc_c.dart` | dart FFI 绑定 `WebrtcCDataPacketCryptor` + 门面方法 | — |
| `win_linux/src/webrtc_media_stream.cc` | 设备名/guid 比较与 settings/GetSources 输出统一套 `SanitizeUtf8ForFlutter`(录音/播放/视频/Select 设备) | `6b715ec` `996bd29` |
| `win_linux/src/webrtc_peerconnection.cc` | encoding 的 `priority`/`networkPriority` 解析与序列化(含 set_parameters / addTransceiver / get 输出) | `749b356` |
| `include/rtc_frame_cryptor.h` + `webrtc_frame_cryptor.cc` | 枚举拆分(`FrameCryptorAlgorithm`/`KeyDerivationAlgorithm`+`Algorithm` 别名), `KeyProviderOptions.key_derivation_algorithm`, `createKeyProvider` 解析 `keyDerivationAlgorithm` | `0c8c46c` `e61445a` |
| `include/rtc_types.h` + `webrtc_base.cc` | `RTCConfiguration.enable_dscp` 字段 + `ParseRTCConfiguration` 解析 `enableDscp` | `749b356` |
| `mac/src/WebrtcRTCDesktopCapturer.mm` | `buildDesktopSourcesList` forceReload 时清 `_screen`/`_window` 缓存 | `ea3d60e` |
| `win_linux/{include,src}/pulse_loopback_capturer.{h,cc}` 新增 + `loopback_capturer_factory_linux.cc` + CMake | linux getDisplayMedia {audio} PulseAudio monitor 采集; factory 条件分发; CMake `HAVE_LIBPULSE`(无 pulse 退化 nullptr) | `7612a48` `f3bccbc` |
| `webrtc.h`/`webrtc.cc` + `mac/src/WebrtcPlugin.mm` + `webrtc_c_desktop.dart`/`webrtc_c.dart` | `webrtc_request_capture_permission` C ABI(mac 真实现 CGPreflight/CGRequest, win/linux 恒 true) + dart 绑定; mac 侧不经主队列防 CLI 死锁 | `ea3d60e` |

> mac 其余 darwin 改动(iOS 音频会话/buttonPressed/VideoPlatformView 等)经核实不适用; FrameCapturer 我们 mac 无对应物。逐条见 §"核实: 不需要引入 / 不适用"。
> **dll 就绪性**: DataPacketCryptor/FrameCryptor 枚举拆分/keyDerivationAlgorithm/enable_dscp 均已在**源码层照抄落地**, 但当前 `lib/win64/libwebrtc.dll` 为旧布局(无 `RTCDataPacketCryptor`/`KeyDerivationAlgorithm`/`FrameCryptorAlgorithm`/`key_derivation_algorithm`/`enable_dscp` 符号与 struct 布局), **运行/链接待 dll 升级后生效**, 已备而待用。
> 编译未跑(no-compile-constraint), 待 win 构建 + mac 真机验证。


## 0. 一句话

上游 75 提交里真正需要我们照抄层跟进的, 集中在 **common/cpp**(win/linux 源头) 的 5 个点, 外加 **common/darwin**(mac 源头) 的少量 iOS/线程修复(桌面 mac 端大多可跳过)。核心缺口:**UTF-8 清理**、**cursor 约束全形式**、**getDisplayMedia audio 约束(系统音频同采)**。这三处全部落在 `webrtc_screen_capture.cc` 这一个文件。

---

## A. win_linux 侧(源头 `common/cpp`)—— 必须跟进

### A1. 桌面源/窗口名 UTF-8 清理
| | |
|---|---|
| 上游改动 | `common/cpp/src/flutter_screen_capture.cc` 3 处 name 字段包 `SanitizeUtf8ForFlutter()`(GetDesktopSources / OnMediaSourceAdded / OnMediaSourceNameChanged) |
| 新增源文件 | `common/cpp/include/flutter_utf8_sanitize.h` + `src/flutter_utf8_sanitize.cc`(平台无关纯 C++, 把非法 UTF-8 序列替换为 U+FFFD) |
| 来源提交 | `e815ac2` "sanitize screen/window names"(desktop); `6b715ec` "sanitize UTF-8 device strings"(device) |
| 我们现状 | `win_linux/src/webrtc_screen_capture.cc` 第 72/241/256 行直接 `MakeStr(source->name().std_string())`, **未清理** |
| 根因 | `source->name()` 可能含非法 UTF-8; 我们 parson 序列化 kStr 时 `json_value_init_string` 遇非法 UTF-8 返回 NULL → JSON 出 `"name":null` 或整体失败 → dart json.decode 异常 |
| 要做的 | ① 把 `flutter_utf8_sanitize.{h,cc}` 抄成平台无关工具进 `webrtc-c/common/`(或 win_linux 内); ② 在 `webrtc_screen_capture.cc` 3 处 name 组装前套 sanitize; ③ (可选) media_stream 设备 id 的同类问题见 A4 |

### A2. getDisplayMedia `cursor` 约束全形式
| | |
|---|---|
| 上游改动 | `flutter_screen_capture.cc`: cursor 从只认字符串 `"never"` 扩展为 `"always"/"never"` + **bool 形式**; 解析逻辑从 `findString` 改为「字符串非空时 `show_cursor=(cursor=="always")`, 否则按 map 里有无 cursor 键再 `findBoolean`」 |
| 来源提交 | `e4053e8` "support the getDisplayMedia cursor constraint" |
| 我们现状 | `webrtc_screen_capture.cc` 第 109-110 行只认 `cursor=="never"`(字符串), **不认 `always` / 不认 bool** |
| 要做的 | 同步解析逻辑到我们的 `GetDisplayMedia` |

### A3. getDisplayMedia `audio` 约束 → 屏幕 + 系统音频同采 (最大新增能力)
| | |
|---|---|
| 上游改动 | `flutter_screen_capture.cc` `GetDisplayMedia` 新增 audio 约束分支: constraints 里 `audio:true|map` 时, 经 `CreateLoopbackCapturer(source_id)` 建 `LoopbackCapturer`, 把系统音频灌进 `RTCAudioSource`, 生成 `RTCAudioTrack`, 同 stream 一起返回(带 `audioTracks`); 同时停掉上一次 loopback。audio 处理关闭 echoCancellation/AGC/NS(系统音频不应被当回声抑制) |
| 新增源文件 | `common/cpp/include/loopback_capturer.h`(平台无关接口 `LoopbackCapturer{Start,Stop}`); `windows/application_loopback_capturer.{h,cc}`(WASAPI 实现); `windows/loopback_capturer_factory.cc`(`CreateLoopbackCapturer(source_id)`, 按 source_id 解析窗口归属进程 PID); linux 侧 `pulse_loopback_capturer.*` + `loopback_capturer_factory.cc`(PulseAudio) |
| 来源提交 | `f3bccbc` "Added loopback capture for windows to capture application and desktop audio" |
| 我们现状 | `webrtc_screen_capture.cc` 的 `GetDisplayMedia` audioTracks **恒空数组**(当时第 171-173 行), 不解析 audio 约束 |
| 关键判断 | 我们的系统音频采集能力原本是**独立的** `WebrtcWinSysAudioCapturer`(WASAPI loopback)+ `WebrtcSysAudioManager`(单例), 经 `webrtc_get_sys_audio_media` 单独暴露。上游是**同一底层能力**(WASAPI loopback 采扬声器)重构为 `LoopbackCapturer` 接口并挂到 getDisplayMedia。 |
| 落地(2026-09-04) | 经确认走 **A 路线**: `LoopbackCapturer` 三件套已原样照抄进 webrtc-c(见 §落地记录), `GetDisplayMedia` 加 audio 分支(带出系统音频轨)。与本仓库既有 `webrtc_get_sys_audio_media`(WebrtcSysAudioManager)双轨并存: 前者服务 getDisplayMedia{a:audio:true} 一次带声, 后者服务显式系统音频采集, 互不影响 |
| 产品取舍 | 若 MyDesk 主控端发起「一屏共享」希望一次 getDisplayMedia 就带出系统声音, 走新 audio 分支; 否则仍可走「getDisplayMedia(画面) + getSysAudioMedia(声音)」两步 |

### A4. 音频设备字符串 UTF-8 清理 + AEC/NS 约束子 map 解析
| | |
|---|---|
| 上游改动 | `common/cpp/src/flutter_media_stream.cc`: ① 设备名/guid 比较改用 `SanitizeDeviceIdFromAudioBuffers(recordingName, recordingGuid)`(防缓冲里非法 UTF-8 使设备 id 匹配失败); ② 新增 `getAudioProcessingFlag` helper: 从 audio 约束 map 读取 echoCancellation/noiseSuppression/autoGainControl/highpassFilter, 支持顶层平铺键 + `mandatory` 子 map + `optional` 列表三种形式 + bool/"true"/"false" 字符串 |
| 来源提交 | `6b715ec`(sanitize); `996bd29` "map echoCancellation/NS/AGC constraints to RTCAudioOptions"(AEC 开关); `b7de12f` "call SetRecordingDevice(0) when no sourceId"(设备默认) |
| 我们现状 | `webrtc_media_stream.cc` **已有** AEC/NS/AGC/highpass 开关解析(第 55-64 行, `ConstrainBool` 读顶层平铺键)。**缺**: ① mandatory/optional 子 map 形式(若 dart 端只传平铺键则无碍); ② 设备名/guid 的 UTF-8 清理 |
| 要做的 | ① 若产品 dart 端已传平铺键, AEC 子 map 解析**可选**; ② 设备字符串 sanitize 建议补(与 A1 同类问题, 可抽同一工具函数) |

### A5. peerconnection —— 主要是性能优化, 枚举不受影响
| | |
|---|---|
| 上游改动 | `common/cpp/src/flutter_peerconnection.cc`: ① Windows 把 AddTransceiver/AddTrack 移到 **platform thread 之外**跑(避免首帧冷启动 ~600ms 卡 platform thread); ② degradation preference 枚举改名 `RTCDegradationPreference::DISABLED` → `MAINTAIN_FRAMERATE_AND_RESOLUTION` |
| 来源提交 | `69fa733` "run AddTransceiver/AddTrack off the platform thread"; (枚举改名的上游 commit 属同批) |
| 我们现状 | `webrtc_peerconnection.cc` 用我们**自维护**的 `include/rtc_rtp_parameters.h`(仍是旧枚举含 `DISABLED`), 不随上游头变 → **枚举改名不影响我们编译**。AddTransceiver 在 platform thread 同步执行 |
| 要做的 | ① 枚举: **不用动**(我们自维护头, 直到升级 libwebrtc); ② 线程优化: 我们 C ABI 本身无 platform thread 概念(webrtc.cc 直接调), 该优化是 upstream Flutter plugin 特定问题 → **不需要**。若将来要避免发端加轨卡顿可另议 |

### A6. 结构类(不改我们)
| | |
|---|---|
| `flutter_webrtc_base.{h,cc}` | 仅暴露 `GetKeyProviderForId` + `friend class FlutterDataPacketCryptor`(给 DataPacketCryptor 用) → 内部结构, 不新增我们需要的 dart 可见能力 |
| `flutter_webrtc.cc` | 仅加 `HandleDataPacketCryptorMethodCall` 分发分支(配 data_packet_cryptor 新文件) |
| `flutter_common.cc` | event channel 生命周期(teardown 不 unregister / host messenger 校验) → 纯 Flutter plugin 内部, C ABI 不消费 flutter messenger, **无关** |
| `flutter_frame_cryptor.{h,cc}` | C++ 枚举拆分: `Algorithm` → `KeyDerivationAlgorithm`(kPBKDF2/kHKDF) + `FrameCryptorAlgorithm`(kAesGcm/kAesCbc) 两个独立枚举; key_provider 存取挪到 base。我们 frame_cryptor 走**自维护头**(旧枚举) → 不破坏编译; **等升级 libwebrtc 时**再同步枚举语义 |
| `flutter_video_renderer.h` | `shared_ptr<uint8_t>` → `shared_ptr<uint8_t[]>` 内部类型, 无关 |
| `loopback_capturer.h` 平台无关头 | 见 A3 |

### A7. DataPacketCryptor(新增能力)
| | |
|---|---|
| 上游新增 | `flutter_data_packet_cryptor.{h,cc}`: 封装 `RTCDataPacketCryptor`(create / encrypt / decrypt / dispose), 对 **data channel 二进制包**做 E2EE(与 FrameCryptor 加密媒体轨是两套); 依赖 libwebrtc 的 `rtc_data_packet_cryptor.h`(我们 include 层原**没有**此头) |
| 来源提交 | 本次 75 提交内(具体为 data_packet_cryptor 相关提交) |
| 落地(2026-09-04) | 已照抄落地(不管 libwebrtc 版本): ① include 自维护补 `rtc_data_packet_cryptor.h`(`RTCDataPacketCryptor::Create` + `EncryptedPacket::Create`, 仿 `rtc_frame_cryptor.h` 风格); ② webrtc-c 新增 `webrtc_data_packet_cryptor.{h,cc}`(`WebrtcDataPacketCryptor` 挂 base, create/dispose/encrypt/decrypt, 复用 `WebrtcFrameCryptor::GetKeyProviderForId` 拿 KeyProvider); ③ `webrtc_frame_cryptor.{h,cc}` 加 `GetKeyProviderForId`; ④ base 加 `data_packet_cryptor_` 成员 + 析构清理; ⑤ `webrtc.h`/`webrtc.cc` 加 4 个 C ABI(`webrtc_data_packet_cryptor_create/dispose/encrypt/decrypt`); ⑥ CMake 加源。dart FFI 绑定(webrtc-cli)尚未加 |
| 备注 | 是否要 dart 侧(webrtc-cli FFI + 业务)真正用上 data channel 加密, 看 MyDesk 是否需要对控制通道做应用层 E2EE, 否则 C ABI 已备而不用 |

---

## B. mac 侧(源头 `common/darwin`)

| 上游 darwin 改动 | 与我们 webrtc-c/mac 关系 | 判定 |
|---|---|---|
| `FlutterRTCDataChannel.m` / `FlutterRTCFrameCryptor.m`: eventQueue/eventSink 加 `@synchronized` + eventSink 置空清理 | 线程安全修复(iOS/ObjC event sink) | 我们 mac 的 data channel / frame cryptor 若是纯回调经 C ABI, 不消费 Flutter event sink → **桌面 mac 端可跳过**; 若照抄了 eventQueue 则按需同步 |
| `FlutterRTCPeerConnection.m`: eventQueue 置 nil 顺序 | 同上 | 同上, 可跳过 |
| `FlutterRTCMediaStream.m`: 加 `audioSessionManagementEnabled` 开关 | iOS audio session 管理 | **iOS 专属**, mac 桌面不用 |
| `FlutterWebRTCPlugin.m`: `postEvent` 判 nil; `gAudioSessionManagementEnabled` 全局开关; platform view factory 改 iOS+macOS 共享 | iOS 线程 + platform view 迁移 | platform view 见下 |
| `FlutterRTCDesktopCapturer.m`: 移除私有 `buttonPressed:` 选择器, 改遍历 subview 找 UIButton | **iOS** 专用(private selector 移除) | **iOS 专属**; 我们 mac 的 WebrtcRTCDesktopCapturer.mm 若没用该 selector 则无关 |
| `AudioUtils.m`: `kAudioSessionProperty_OverrideAudioRoute` → `AVAudioSessionPortOverrideSpeaker` | iOS | 无关 |
| `FlutterRTCFrameCapturer.m`: captureFrame 写文件前创建父目录 | macOS 可用 | 若我们 mac 照抄了 FrameCapturer 写文件, 可同步(小改); 桌面被控端一般不用 FrameCapturer |
| **新增 `FlutterRTCVideoPlatformView*` 6 文件, 从 `ios/Classes/` 移到 `common/darwin/Classes/`(iOS+macOS 共享)** | 桌面 mac 是否用 platform view 渲染远端视频? | MyDesk mac 被控端是 FFI + 自渲染, **不用** Flutter platform view → **不引入**。仅当未来 mac 端要用 Flutter 原生 widget 显示远端流才需要 |
| `FlutterScreenCaptureKitCapturer.*`(新增) | ScreenCaptureKit 采集器 | 见下 C |

### mac 侧结论
mac 这次真正值得同步的: ① (可选) `FlutterRTCFrameCapturer` 写文件建父目录小修; ② 若我们 mac 照抄了 data channel / frame cryptor 的 eventQueue 结构, 同步线程安全(需逐文件确认我们 mac 实现是否含该结构)。**平台视图、iOS 音频会话、iOS buttonPressed 均不引入。**

---

## C. ScreenCaptureKit 采集器(mac, 新增)

上游 macos 新增 `FlutterScreenCaptureKitCapturer.{h,m}`(ScreenCaptureKit 采集器, 见 windows 侧同批 commit `macos/.../FlutterScreenCaptureKitCapturer.m`)。我们 mac 的 `WebrtcRTCDesktopCapturer.mm` 目前用老桌面采集。是否切 ScreenCaptureKit 属**采集路线升级**(与上游 mac 采集器演进相关), 需在 mac 编译验证时单独评估, 不在本次 webrtc-c 同步主清单。

---

## 汇总核对(2026-09-04 已全部落地/判定, 细节见 §落地记录)

| # | 项 | 状态 |
|---|---|---|
| 1 | utf8_sanitize 工具 | ✅ `common/flutter_utf8_sanitize.{h,cc}` |
| 2 | 桌面源 name sanitize(3 处) | ✅ `webrtc_screen_capture.cc` |
| 3 | cursor 约束 always/never+bool | ✅ `webrtc_screen_capture.cc` |
| 4 | getDisplayMedia audio 约束 + LoopbackCapturer 三件套 | ✅ A 路线照抄(见 A3) |
| 5 | 设备字符串/guid sanitize | ✅ `webrtc_media_stream.cc`(全设备路径) |
| 6 | DataPacketCryptor C ABI + include + dart FFI | ✅ 已照抄(dll 升级后生效, 见下) |
| 7 | encoding priority/networkPriority | ✅ `webrtc_peerconnection.cc`(`749b356`) |
| 8 | frame_cryptor 枚举拆分 / keyDerivationAlgorithm | ✅ include 头已拆(`FrameCryptorAlgorithm`/`KeyDerivationAlgorithm`+`Algorithm` 别名)+ `createKeyProvider` 解析 `keyDerivationAlgorithm`(运行等 dll) |
| 9 | enable_dscp | ✅ `rtc_types.h` 加字段 + `ParseRTCConfiguration` 解析 `enableDscp`(运行等 dll) |
| 10 | 1879232 ParseConstraints 崩溃修复 | ⏭ 不需要(JNode 版已安全) |
| 11 | mac DataChannel 线程安全 | ✅ `WebrtcRTCDataChannel.mm` |
| 12 | mac SysAudio 占位迁移 + ios 坏占位修复 | ✅ 已 staged |
| 12b | mac 桌面源刷新 forceReload 清缓存 | ✅ `WebrtcRTCDesktopCapturer.mm`(`ea3d60e`) |
| 13 | ScreenCaptureKit 采集器 | ⏸ 采集路线升级, mac 验证时单独评估 |
| 14 | DataPacketCryptor/FrameCryptor 的 dart 层真正用起来 | ⏸ 视 MyDesk 是否需 data channel 应用层 E2EE |
| 15 | linux getDisplayMedia {audio} (pulse_loopback_capturer) | ✅ 照抄 `pulse_loopback_capturer.{h,cc}` + factory 真分发 + CMake `HAVE_LIBPULSE`(无 pulse 退化 nullptr) |
| 16 | mac requestCapturePermission (CGRequestScreenCaptureAccess) | ✅ `webrtc_request_capture_permission` C ABI(mac 真实现, win/linux 恒 true) + dart 绑定。**不经主队列**: CLI 无主 RunLoop, dispatch_sync(main) 会死锁; CGRequest 系统弹框任意线程可弹 |

> 说明: DataPacketCryptor 的 C ABI + dart 绑定、frame_cryptor 枚举拆分、KeyProviderOptions.key_derivation_algorithm、RTCConfiguration.enable_dscp 均已**照抄进 include/源码层**; 但当前 `lib/win64/libwebrtc.dll` 为旧布局(无 `RTCDataPacketCryptor`/`KeyDerivationAlgorithm`/`FrameCryptorAlgorithm`/`key_derivation_algorithm`/`enable_dscp` 符号与 struct 布局), **源码已就位, 运行/链接待 dll 升级后生效**。已备而待用。

## 核实: 不需要引入 / 不适用(逐条核对过, 防止误以为漏)

| 上游提交/改动 | 内容 | 为什么我们不跟 |
|---|---|---|
| `69fa733` peerconnection 线程优化 | Windows 把 AddTransceiver/AddTrack 移到 platform thread 外 | 我们 C ABI 无 Flutter platform thread 概念, webrtc.cc 直接调; 上游优化针对 Flutter plugin 卡顿 |
| `7193b40` `c5f6083` `15fcf62` event channel/线程 | event channel use-after-free / teardown 不 unregister / MethodResultProxy 回主线程 | 纯 Flutter event channel/plugin 内部, C ABI 不消费 Flutter messenger/event sink |
| `flutter_common.cc` 生命周期(3 commits) | teardown 时 host messenger 校验等 | 同上, Flutter plugin 内部 |
| `1879232` ParseConstraints 崩溃修复 | 上游对未识别约束值类型 `GetValue<int>` 抛异常 → 改 `continue` | 我们 JNode 版 ParseConstraints 对数组/对象本就 `continue`, 无此 bug |
| `5758c0d` renderer 内存 | `shared_ptr<uint8_t>` → `shared_ptr<uint8_t[]>`(rgb_buffer delete[] 修正) | 改上游 Flutter 渲染缓冲(FlutterVideoRenderer); 我们 `rtc_video_renderer.h` 只是模板接口, 无 rgb_buffer |
| `10cbda8` mac platform rendering + `FlutterRTCVideoPlatformView*` 新增/移动 | darwin 新增 video platform view(iOS+macOS 共享) | MyDesk mac 被控端 FFI + 自渲染, 不用 Flutter platform view |
| iOS 专属: `df2b984`(模拟器麦克风) `d4ee1d2`/`996bd29` 硬件 AEC(android) `8e5d9f7`/`b42d02e`/`283a792` 屏幕旋转 `7fd9496`/`2f1b6ad`/`84c90d7` 等 | iOS/Android 摄像头/采集/线程修复 | 平台专属, 不涉及我们 win_linux/mac 照抄的 common/cpp+darwin 公共代码 |
| `d1f0906`/`AudioUtils.m` 扬声器端口 | iOS `kAudioSessionProperty_OverrideAudioRoute`→`AVAudioSessionPortOverrideSpeaker` | iOS 专属 |
| `93aa7ac` microphone mute / ADM mute | setMicrophoneMuted(Android/Darwin 音频设备模块) | 不碰 common/cpp win/linux |
| `040d222`/`040d222` audio session ownership | 允许 embedder 接管 audio session 管理 | iOS/mac audio session, 与 webrtc-c 桌面无关 |
| `dd3c94c`/`78cb0b6` AVAudioEngine 切换 | mac/iOS 从 CoreAudio ADM 切 AVAudioEngine(需 WebRTC-SDK 144.7559.04+) | 我们 mac WebrtcPlugin.mm 已走 AudioEngine/RTCAudioDeviceModule 新框架, 方向一致无需同步 |
| `a01a8f0` mac warnings 清理 | FlutterScreenCaptureKitCapturer 声明清理 + plugin 小改 | 改的是 ScreenCaptureKitCapturer(我们未引入)+ plugin 内部 |
| `5ad4545` darwin FrameCryptor 事件投递 | eventQueue + @synchronized 缓存, eventSink 就绪后补发 | 我们 mac WebrtcRTCFrameCryptor.mm 用 delegate 模式(C ABI 回调), 无 Flutter event sink/eventQueue |
| `e17e53b`/`8bc3ada`/`ea3d60e` ScreenCaptureKit/legacy capturer | mac 屏幕采集切 ScreenCaptureKit(Monterey 回退) + 源刷新 + requestCapturePermission | ScreenCaptureKit 切换归 mac 真机阶段(单独评估); **源刷新已跟**(#12b)、**权限请求已跟**(#16) |
| `0240c15` mac FrameCapturer 建父目录 | captureFrame 写文件前创建目录 | 我们 mac 无 FlutterRTCFrameCapturer 对应物 |
| `7612a48`/`f3bccbc` PulseAudio/应用 loopback 内部 | 见汇总 #4/#15 | **已跟**(win 三件套 + linux pulse) |
| `2eb8e41` SPM 集成 + `macos/Classes`/`ios/Classes` 占位迁移 | pod/SPM 布局重构 | 我们 SysAudio 占位迁移已完成(见 #12) |
| `4e6870e` CMake 二进制下载重构 | third_party 下载流程重构 | 非 webrtc-c 源, 与 C ABI 无关 |
| darwin `FlutterRTCMediaStream.m` audioSessionManagementEnabled / `buttonPressed:` 移除 | iOS audio session / 广播 picker | iOS 专属 |

> 判定方法: 逐提交 `git show <hash> -- <照抄源>` 核对; "我们 X 没有对应物"均经 grep 验证(如 mac 无 FrameCapturer、无 eventQueue、无 rgb_buffer)。

---

## 附: 核实方法(以后可复用)
- 本次上游改动范围: `git diff origin/zjn..zjn_1.6.1 -- common/cpp common/darwin windows linux`
- 上游新增文件: `git diff --name-status -M origin/zjn..zjn_1.6.1 | grep -E "^A|^R"`(R 为移动)
- 我们 webrtc-c 是否被合并改动: `git diff origin/zjn..zjn_1.6.1 -- third_party/libwebrtc/webrtc-c/`(当前为空)
- 关键 commit 是否本次合入: `git merge-base --is-ancestor <hash> origin/zjn`
