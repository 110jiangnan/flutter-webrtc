# webrtc-c 构建与测试（webrtc-cli 的 FFI 底层 DLL）

本文与 [windowslinux迁移方案.md](./windowslinux迁移方案.md) 配套：迁移方案讲**架构与 ABI**，本文讲**编译命令、踩过的坑、验证方法**（即 mydesk 项目的实操记忆落地）。DirectShow 摄像头线程问题（sink_filter_ds.cc:735 崩溃机制）单独成文：[webrtc-directshow线程问题.md](./webrtc-directshow线程问题.md)。

## 0. 一句话结论

- `third_party/libwebrtc/webrtc-c/` 是 **C++ C ABI** 动态库，封装 `libwebrtc.dll` 给 Dart FFI 用（`webrtc-cli` 包），**只服务 MyDesk 被控端**（录屏/系统音频/麦克风/摄像头 + DataChannel，应答主控的 offer）。
- 结构完全按 `flutter-webrtc/common/cpp` 分模块（拒绝单文件屎山）：`webrtc_base`（factory+设备）、`webrtc_media_stream`（getUserMedia）、`webrtc_peerconnection`（PC/SDP/ICE）、`webrtc_data_channel`、`webrtc_screen_capture`、`webrtc_sys_audio_*`。
- 跨边界约定：**不透明句柄 + JSON 字符串 + C 回调**，不暴露任何 C++ 类型。事件/结果都走回调。

## 1. Release 编译命令

写死在 `webrtc-c/win.ps1`，一条命令：

```powershell
powershell -ExecutionPolicy Bypass -File win.ps1
```

产物：`build_vs\Release\webrtc_c.dll` + 同目录自动拷入 `libwebrtc.dll`（POST_BUILD）。

硬约束（都是踩过的坑，别改）：

| 约束 | 原因 |
|---|---|
| **只能用 MSVC**（VS2022 `-G "Visual Studio 17 2022" -A x64`） | `libwebrtc.dll` 是 MSVC/clang-cl 构建的，MinGW(gcc/g++) 链动会报 `__imp_... undefined`，永远链不动 |
| cmake ≥ 3.29 | 用 Qt 自带的 `E:\home\qt\Tools\CMake_64\bin\cmake.exe`（3.30.5）；PATH 里 3.26 不够 |
| `RTC_DESKTOP_DEVICE` 已在 CMakeLists 定义 | 不定义则 vtable 错位，getUserMedia 在 GetAudioDevice 全崩（不用在命令行重复） |
| 清 `_CL_` 环境变量 | git-bash 跑 powershell 会继承 `_CL_=/D_SILENCE_STDEXT_HASH_DEPRECATION_WARNINGS`，破坏 cl 的 `/D` 参数 |

Dart 侧加载器候选已含 `build_vs\Release`（排在 Debug 前）；也可用环境变量 `WEBRTC_C_LIB` 指定路径。

## 2. 踩过的坑（8 条）

1. **MinGW vs MSVC DLL 不兼容**：导出表是 MSVC C++ 名字修饰，导入库格式不兼容，MinGW 永远链不动，不是代码问题。
2. **RTC_DESKTOP_DEVICE vtable 错位**：DLL 用 desktop capture 编的，接口里 GetDesktopDevice 在此宏下；不定义则后面所有虚函数调用全崩。
3. **`_CL_` 环境变量**：git-bash 预置，MSYS 下被改写成路径导致 cl 崩；`unset _CL_` 或 MSYS2_ARG_CONV_EXCL。
4. **Dart 加载 error 126**：先 `DynamicLibrary.open` 同目录的 `libwebrtc.dll`，否则加载器不搜 DLL 所在目录。
5. **WASAPI loopback COM**：主线程可能已被 getUserMedia 初始化为 MTA，CoInitializeEx(APARTMENTTHREADED) 报 `RPC_E_CHANGED_MODE(0x80010106)`；要容忍并复用，只在自初始化成功时才 CoUninitialize。
6. **跨线程回调指针必须堆拷贝（大坑）**：C 侧把栈上 `std::string` 的 `json.c_str()` 直接传给 `webrtc_event_cb`/`webrtc_result_cb`，而 Dart 侧是 `NativeCallable.listener` —— **从 webrtc 线程（非主 isolate 线程）调用时，Dart 回调会被异步编组到 isolate 延迟执行，届时栈上字符串已析构 → 悬垂指针**。症状不定：乱码 UTF-8（`FormatException: Missing extension byte`）/空串（`Unexpected end of input`）/偶发崩溃。主线程同步调用没事，所以只在 offer/answer/stats 等 webrtc 线程异步回调时炸。
   **修复**：C 侧一律传 `StrDup(json)`（malloc），data channel 二进制同样 malloc 拷贝；Dart 侧 `_onEvent`/`_onResult` 读完后 `webrtc_free_string` 释放。注意 `webrtc_free_string` 就是 `free`，**别传字面量字符串**否则 free 静态内存崩溃（`onDeviceChange` 那处字面量也要改成 StrDup）。
   **衍生坑（parson double）**：parson 用 `%1.17g` 序列化，`1.0` 会写成 `1` → Dart jsonDecode 得 `int`，赋值给 webrtc_interface 的 `double?` 字段（如 `RTCRtpEncoding.scaleResolutionDownBy`）会 `type 'int' is not a subtype of type 'double?'`。需在 webrtc-cli 边界（`rtc_rtp_utils.dart`）把 `num` 归一化成 `double`。
7. **Dart 进程退出挂住**：`NativeCallable.listener` 默认 keep-isolate-alive + EventBus 挂着不关的 ReceivePort 会把 isolate 钉死，`dispose()` 后进程不退（timeout 124）。修复：
   - 本 SDK（Dart 3.13 / Flutter 3.47）里 `keepIsolateAlive` 是**可写属性**（不是构造参数，当构造参数传直接编译错），在 `EventBus.init()` 里置 `false`；
   - 另加 `EventBus.close()`（关 port 订阅 + close NativeCallable），挂到全局 `dispose()`。注意 close 后不可复用（dispose 是进程退出一次性）。
8. **紧 FFI 循环饿死 Dart 事件循环（2026-08-22 压力测试定位）**：DataChannel 持续发送时，发送循环里 `await dc.getBufferedAmount()`（同步 FFI、返回**已完成**的 Future）**只让给微任务队列，不让给事件循环**；紧接着 `dc.send()` 也是同步 FFI，下一轮又 `await` 已完成 Future……循环每轮都往微任务队列塞活，**宏任务（定时器、ReceivePort 消息）永远排不上**——本质相当于"死循环卡住队列"，线程没真死但事件循环被堵死。两个诡异症状都由此而来：
   - **同进程接收端(B)永远收不到消息**：webrtc 线程回调 → NativeCallable → **ReceivePort(宏任务)** 投递，事件循环被堵 → B 显示 0 接收（A 却发得飞起）。
   - **主循环 `await Future.delayed(1s)`(定时器=宏任务) 永不触发 → 90s 截止检查不执行 → 测试跑飞 20 分钟**。
   修复：发送循环每发一批后必须 `await Future.delayed(1ms)`（真正的定时器=宏任务）让出事件循环，既保吞吐又让接收端事件/截止定时器能被处理。验证：只用 getBufferedAmount 时 B 收 0；加 `Future.delayed` 后 A 发 215.8MB/B 收 215.8MB 100% 送达，90s 全量 A 发 1538.5MB 全收且按时停。
   **本质一句话**：`await` 一个**已完成**的 Future 只让出微任务，事件循环没机会跑；必须 `await` 一个**还没完成**的宏任务（如 `Future.delayed`）才能真正让事件循环处理 B 的接收和截止定时器。

## 3. 测试验证

**冒烟测试**（覆盖 createPC/getUserMedia/getDisplayMedia/桌面源/系统音频/能力查询/设备枚举）：

```bash
cd E:\game\MyDesk\MyDesk\flutter-webrtc\webrtc-cli
E:/home/flutter/flutter_windows_3.47.0-0.1.pre-beta/flutter/bin/cache/dart-sdk/bin/dart.exe tool/smoke.dart
```

**综合测试**（3 轮：A 发端全量采集 + B 收端，SDP/ICE 交换 + DataChannel 双向 + 30s stats + 资源释放检查）：

```bash
cd E:\game\MyDesk\MyDesk\flutter-webrtc\webrtc-cli
E:/home/flutter/flutter_windows_3.47.0-0.1.pre-beta/flutter/bin/cache/dart-sdk/bin/dart.exe test/testMain.dart
```

验证结果（2026-08-22 实测，release libwebrtc）：3 轮全过，**0 致命错误，EXIT=0 干净退出**。每轮日志：屏幕+麦克风+**摄像头**+系统音频采集成功，SDP/ICE 交换后 `ICE Connected/Completed`，DataChannel 双向各收 4 字符串 + 1 二进制，stats 显示真实媒体流，资源释放干净，`全局 factory 已释放`。

**摄像头曾经必崩，根因是运行时加载了 debug 版 libwebrtc.dll（2026-08-22 定位，已修）**：`test/serverA.dart` 的摄像头段曾注释禁用。现象是 `modules/video_capture/windows/sink_filter_ds.cc:735` 的 `RTC_DCHECK_RUN_ON(&capture_checker_)` 线程 CHECK 崩溃（`Threads don't match`），只在摄像头帧流入编码器时崩、OBS 虚拟摄像头环境必现；不是 wrapper 问题（wrapper 与 flutter-webrtc 逐行一致）。真相：`sink_filter_ds.cc` 的 `CaptureInputPin::Receive()` 用 `SequenceChecker` 检查样本投递线程，OBS 虚拟摄像头这类 DirectShow 源把样本**跨线程投递**（第一次 Receive 绑定线程后换线程就 CHECK）；而 `RTC_DCHECK` 只在 debug 构建生效。**flutter-webrtc 不崩纯粹因为发布的是 release libwebrtc（NDEBUG 把 DCHECK 编译掉），上层代码并无差异**。修复：用 `E:\game\MyDesk\MyDesk\libwebrtc\src\libwebrtc\build\win64.txt` 的命令重新编译 release libwebrtc（`is_debug=false`），把 `libwebrtc.dll`+`.lib` 拷到 `third_party/libwebrtc/lib/win64` 和 `webrtc-c/build_vs/Release`，重链 `webrtc_c.dll`（win.ps1）。**部署 libwebrtc.dll 前务必确认是 release 构建**（约 20MB；debug 版 55MB，带 msvcp140d/ucrtbased debug CRT）。验证：`tool/repro_cam_mic.dart` 换 release 前摄像头 5s 内必崩、换后 mic+cam 均存活；摄像头段已取消注释。

**压力测试**（系统音频 + DataChannel 大流量，2026-08-22 新增）：

```bash
cd E:\game\MyDesk\MyDesk\flutter-webrtc\webrtc-cli
# STRESS_SECONDS 控时长(默认 90s); 测试前用 PowerShell 循环播放音调让系统音频有数据
E:/home/flutter/flutter_windows_3.47.0-0.1.pre-beta/flutter/bin/cache/dart-sdk/bin/dart.exe test/sysaudio_dc_stress.dart
```

已实测（90s，release libwebrtc）：系统音频 RTP 有真实流量（A 发出 44.3MB，B onTrack 收到 audio），DataChannel **A 发 1538.5MB / B 收 1538.5MB 100% 送达**、全程 ~17MB/s、bufferedAmount 限流、无崩溃干净退出。脚本要点：发送循环每发一批必须 `await Future.delayed(1ms)` 让出事件循环（见坑 8），deadline+字节上限双看门狗防跑飞。最小复现：`test/minimal_dc_continuous.dart`（ServerA/ClientB + 持续发送，用于隔离脚本 bug 还是库问题）。
