# macOS webrtc-c 编译与运行踩坑实录（给 AI 的速查）

> 本文是 mac 移植（`third_party/libwebrtc/webrtc-c/mac/`，ObjC over WebRTC.xcframework）在 **首次编译 + 首次运行** 时踩过的坑和修复。与 [macos迁移方案.md](./macos迁移方案.md) 配套：迁移方案讲架构，本文讲"编译/运行会炸什么、怎么修"。
> **下次开新会话直接读本文，别重新踩。**

## 0. 编译命令（已封装成脚本）

```bash
cd third_party/libwebrtc/webrtc-c
./build_mac.sh                 # 一键编译 arm64+x86_64 通用 libwebrtc_c.dylib
WEBRTC_XCFRAMEWORK=<路径> ./build_mac.sh   # 指定 xcframework
```

- 产物：`build_mac/dist/libwebrtc_c.dylib`（arm64+x86_64），部署到 `webrtc-cli/native/`
- WebRTC.xcframework 唯一候选：`~/Desktop/zjn/deploy/Specs/WebRTC.xcframework`（`macos-arm64_x86_64` 切片）
- 依赖：`cmake >= 3.29`（本机 brew 装的 4.2.3）、Xcode 命令行工具
- 脚本内部：`-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` + `-DCMAKE_OBJCXX_FLAGS=-F<切片目录>`（`#import <WebRTC/...>` 需要）+ `-DWEBRTC_MAC_FRAMEWORK=<切片>/WebRTC.framework/WebRTC`；后处理 `install_name_tool` 设 `@rpath` + rpath `@loader_path` + `@executable_path/../Frameworks` + 本地切片绝对路径

---

## 1. 编译期（CMake / 源码）

| 问题 | 现象 | 修复 |
|------|------|------|
| **OBJCXX 语言未启用** | `CMake Error: The language OBJCXX was requested... not enabled` | `CMakeLists.txt` APPLE 分支加 `enable_language(OBJCXX)`（`project()` 只启了 C/CXX） |
| **ARC 未开启** | `error: cannot create __weak reference in file using manual reference counting` | APPLE 分支 `target_compile_options(webrtc_c PRIVATE -fobjc-arc)`（darwin Pod 的 CLANG_ENABLE_OBJC_ARC=YES） |
| **`webrtc/webrtc.h` 路径不存在** | `file not found: webrtc/webrtc.h` | `WebrtcPlugin.h` 里 `#import "webrtc/webrtc.h"` → `#import "webrtc.h"`（头在 `mac/include/webrtc.h`，无 `webrtc/` 子目录） |
| **`AudioManager` 类型未知** | `unknown type name 'AudioManager'` 级联一堆错 | `WebrtcPlugin.h` 补 `#import "AudioManager.h"` |
| **`RTCFrameCryptorDelegate` 未遵循** | `assigning to 'id<RTCFrameCryptorDelegate>' from 'WebrtcPlugin *'` | `WebrtcPlugin.h` 协议列表加 `RTCFrameCryptorDelegate` |
| **视频编解码工厂类缺失** | `unknown type name 'VideoDecoderFactory'` 等 | `WebrtcPlugin.mm` 移植 darwin 私有类 `VideoEncoderFactory/VideoDecoderFactory/VideoEncoderFactorySimulcast` + `motifyH264ProfileLevelId`（在 `FlutterWebRTCPlugin.m` 顶部） |
| **`dataChannels`/`parseMediaConstraints:` 未声明** | `property 'dataChannels' not found` / `no visible @interface declares 'parseMediaConstraints:'` | 各 `.mm` 补 `#import "WebrtcRTCPeerConnection.h"`（category 声明所在）；`peerConnectionClose:` 也要在 `.h` 声明 |
| **`track.enabled` 不存在** | `property 'enabled' not found on RTCMediaStreamTrack` | 用 `track.isEnabled` |
| **`uint8_t` 指针转换** | `cannot initialize 'const uint8_t*' from 'const void*'` | `(const uint8_t*)data.bytes` |

---

## 2. 运行时崩溃 / 卡死（mac 特有，重中之重）

### 2.1 双重释放 → `pc.close()` 崩溃（ILL_ILLOPC）

- **现象**：`createOffer` 返回 null / 空 sdp；`pc.close()` 时崩溃，栈尾 `free_small → deque::~deque → WebRtcSessionDescriptionFactory::~`，`purgeable_print_self.cold.1`。
- **根因**：`NativeCallable.listener` 跨线程调用是**异步编组**——`cb()` 只把消息排队到 isolate 就返回。C 侧 `WebrtcResultFire` 调 `cb(ud, 0, copy)` 后 `free(copy)`，Dart 侧 `_onResult` 读时指针已悬垂（use-after-free）+ 再 `webrtc_free_string` 双重释放 → heap 损坏。
- **修复**：C 侧 malloc 拷贝后**不能 free**，所有权转交 Dart（`_onEvent`/`_onResult` 读完后 `webrtc_free_string` 释放）。涉及 `WebrtcResultFire`、`WebrtcResultMake` 错误路径、`WebrtcEventCallback post:/postString:`。二进制 data channel 消息同样 malloc 拷贝（不能传 `NSData.bytes`，Dart 会 free）。

### 2.2 `dispatch_get_main_queue()` 永不执行 → 所有事件丢失

- **现象**：ICE gathering 0 candidates、DataChannel 连不上、`getUserMedia` 30s 超时。C 侧 `didGenerateIceCandidate:` 正常触发，Dart 侧收不到。
- **根因**：Dart CLI 进程（webrtc-cli 测试/无头 server）**没有 NSApplication/RunLoop**，`dispatch_async(dispatch_get_main_queue(), ...)` 的 block 永不执行。
- **修复**：事件直接调 `cb(ud, copy, ...)`（NativeCallable.listener 自带跨线程编组到 isolate），不走 main queue。涉及 `WebrtcEventCallback post:/postString:`、`WebrtcRTCPeerConnection.mm didOpenDataChannel:`、`WebrtcRTCMediaStream.mm` 权限回调。darwin 派发主线程是因为 Flutter eventSink 要求，C ABI 不需要。

### 2.3 `RTCAudioDeviceModuleDelegate` 9 个必选方法缺失

- **现象**：`-[WebrtcPlugin audioDeviceModule:didCreateEngine:]: unrecognized selector`。
- **根因**：新框架（macOS 26.2 SDK）的 `RTCAudioDeviceModuleDelegate` 协议有 9 个必选方法（引擎生命周期钩子），darwin 只实现旧协议的 `audioDeviceModuleDidUpdateDevices:`。
- **修复**：`WebrtcPlugin.mm` 全量实现 9 个方法，引擎钩子返回 0，`audioDeviceModuleDidUpdateDevices:` 发 `onDeviceChange`。

### 2.4 B 端远程 DataChannel 收不到大流量（1.4%）

- **现象**：压力测试 A 发 444MB，B 只收 18.9MB（`eventQueue` 积压）。
- **根因**：`didOpenDataChannel:` **没给远程 DC 设置事件回调**，消息全进 `eventQueue`（`channel.eventQueue = [eventQueue arrayByAddingObject:event]` O(n²)），native 线程卡死。
- **修复**：`didOpenDataChannel:` 里 `dataChannel.webrtcEventCallback = peerConnection.webrtcEventCallback`（继承 PC 回调，对应 darwin 建 eventChannel 的步骤）。

### 2.5 音频 race → `audio_send_stream.cc:368` Fatal

- **现象**：麦克风 + 系统音频同时采集时 `Fatal error: Check failed: !race_checker368.RaceDetected()`。
- **根因**：系统音频 track 被 addTrack 到**普通 PC**（peerConnectionFactory）。系统音频是 custom source（`RTCAudioSource onAudioData:` 从 ScreenCaptureKit 线程推帧），流归属 peerConnectionFactory 的 AudioState；麦克风 ADM 录音时 `AudioTransportImpl::SendProcessedData` 把帧广播给**所有** `audio_senders_`（含系统音频流）→ 两个线程并发调同一 `AudioSendStream::SendAudioData`（`capture_lock_`/`sink_lock_` 两把锁不互斥）。
- **修复（架构约束）**：**系统音频必须用 `isSysAudio=true` 的专用 PC**（`createPeerConnection` 传 `isSysAudio: true`，mac 侧用 emptyPcFactory 创建）。被控端**两个 PC**：
  ```
  PC-A (普通):      屏幕 + 麦克风 + 摄像头 + DataChannel
  PC-B (isSysAudio): 系统音频（custom source，空 ADM）
  ```
  Windows 走 WASAPI loopback 无此限制。测试已改：`serverA.dart`/`clientB.dart`（独立系统音频 PC）+ `testMain.dart`（`connectSysAudioPeers`）。

### 2.6 `getUserMedia` 永久卡死

- **现象**：CLI 进程调用 `getUserMedia` 永久挂起（无权限弹窗时回调不来）。
- **根因**：`dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER)` 无超时。
- **修复**：30s 超时 + 失败返回 `{"error":"..."}` JSON，Dart 侧 `factory.dart` 检查 `response['error']` 抛具体错误。

### 2.7 TCC 权限弹窗

- **现象**：CLI 进程摄像头/麦克风无权限弹窗，`getUserMedia` 超时。
- **根因**：macOS 不自动弹权限框，需主动 `[AVCaptureDevice requestAccessForMediaType:...]`。
- **修复**：`WebrtcRTCMediaStream.mm` `getUserMedia:` 开头按 constraints 的 audio/video 请求授权（`dispatch_group` 等待），拒绝返回 `PermissionDenied`。若状态是已拒绝（非 NotDetermined），不弹窗，需去系统设置 → 隐私 → 麦克风/摄像头 手动开。

---

## 3. 发送循环 yield 节奏（Dart 测试脚本）

- **坑**：`sysaudio_dc_stress`/`minimal_dc_continuous` 发送循环每批只 `await Future.delayed(1ms)`，A 全速发送（SCTP 快）饿死 B 的 ReceivePort → B 收不到。
- **修复**：**每批 yield 10ms**（mac 上 1ms 不够，Windows 1ms 够因为发送慢）。

---

## 4. 验证结果（2026-08-23 实测）

- **`testMain.dart` 3 轮全过**：屏幕 + 麦克风 + 系统音频（独立 PC）采集，SDP/ICE 交换，DataChannel 双向收发，RTP 真实传输，无崩溃，`全局 factory 已释放`。
- **`sysaudio_dc_stress` 压力测试**：A 发 368MB / B 收 368MB **100% 送达**，EXIT=0。
- 摄像头在本机无设备 → `NotFoundError`（正常）。
