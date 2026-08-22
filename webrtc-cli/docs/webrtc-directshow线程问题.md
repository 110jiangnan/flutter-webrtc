# webrtc DirectShow 摄像头线程问题（sink_filter_ds.cc:735 崩溃）

> 2026-08-22 定位。现象、根因、线程模型、以及为什么 debug/release 行为不同。详见 [webrtc-c构建与测试.md](./webrtc-c构建与测试.md) 的修复过程；本文专注**线程机制本身**。

## 1. 一句话结论

libwebrtc 的 Windows DirectShow 摄像头采集，在 `CaptureInputPin::Receive()`（DirectShow 流线程回调）里用 `SequenceChecker` 断言**样本必须始终从同一个线程投递**。OBS 虚拟摄像头这类 DirectShow 源把样本**跨线程投递**，于是第二次换线程就触发 `RTC_DCHECK_RUN_ON(&capture_checker_)` 致命崩溃。这个 DCHECK 只在 **debug 构建**（`NDEBUG` 未定义）生效；release 构建把它编译掉，所以 flutter-webrtc（发布 release libwebrtc）同样代码不崩。

## 2. 崩溃现场

```
# Fatal error in: ..\..\modules\video_capture\windows\sink_filter_ds.cc, line 735
# last system error: 0
# Check failed: (&capture_checker_)->IsCurrent()
# # Expected: TQ: 0000000000000000 Thread: 0000000000006160
# Actual:   TQ: 0000000000000000 Thread: 0000000000003DEC
Threads don't match
```

- `Expected Thread 0x6160`：`capture_checker_` 第一次被调用（第一次收到样本）时绑定的线程。
- `Actual Thread 0x3DEC`：后续某次 `Receive()` 实际运行的线程。
- 崩在 setLocalDescription 之后、摄像头帧流入编码器时（帧持续投递才踩得到）。

## 3. 相关源码（webrtc 版本见 `E:\game\MyDesk\MyDesk\libwebrtc\src`）

### 3.1 `sink_filter_ds.h:92-99` — 两个 checker + 线程 id

```cpp
SequenceChecker main_checker_;      // 图构建/状态线程
SequenceChecker capture_checker_;   // 样本投递线程(本问题主角)
VideoCaptureCapability resulting_capability_;
DWORD capture_thread_id_ = 0;       // 只在首次 Receive 设置一次
```

### 3.2 `sink_filter_ds.cc` — checker 生命周期

```cpp
// :385 CaptureInputPin 构造(线程 = 调用 StartCapture 的 webrtc worker 线程)
CaptureInputPin::CaptureInputPin(CaptureSinkFilter* filter) {
  capture_checker_.Detach();          // 解绑
  ...
}

// :406 过滤器从 Paused → Running 时被回调(仍在 main_checker_ 线程 = 图线程)
void CaptureInputPin::OnFilterActivated() {
  RTC_DCHECK_RUN_ON(&main_checker_);
  ...
  capture_checker_.Detach();          // 再解绑一次
  capture_thread_id_ = 0;
}

// :734-749 DirectShow 源 push 一帧样本 → 流线程回调
STDMETHODIMP CaptureInputPin::Receive(IMediaSample* media_sample) {
  RTC_DCHECK_RUN_ON(&capture_checker_);   // :735 崩溃点
  ...
  if (!capture_thread_id_) {              // :745 首次才设线程名
    capture_thread_id_ = GetCurrentThreadId();
    webrtc::SetCurrentThreadName("webrtc_video_capture");
  }
  ...
  filter->ProcessCapturedFrame(sample_props.pbBuffer, ...);  // :773 交给 VideoTrackSource
}
```

### 3.3 `SequenceChecker` 绑定语义（`rtc_base/synchronization/sequence_checker_internal.cc:33`）

```cpp
bool SequenceCheckerImpl::IsCurrent() const {
  ...
  if (!attached_) {          // 之前 Detach 过 → 把当前线程绑上去, 返回 true
    attached_ = true;
    valid_thread_ = current_thread;
    valid_queue_ = current_queue;
    return true;
  }
  if (valid_queue_) return valid_queue_ == current_queue;   // 绑定了队列则比队列
  return IsThreadRefEqual(valid_thread_, current_thread);   // 否则比线程
}
```

要点：**首次调用绑定、后续必须同线程/同队列**。`Detach()` 只是把 `attached_` 置 false，下一次 `IsCurrent()` 重新绑定。

### 3.4 DCHECK 开关（`rtc_base/checks.h:17`）

```cpp
#if !defined(NDEBUG) || defined(DCHECK_ALWAYS_ON)
#define RTC_DCHECK_IS_ON 1     // debug: 生效
#else
#define RTC_DCHECK_IS_ON 0     // release(is_debug=false): NDEBUG 定义 → 编译掉
#endif
```

`RTC_DCHECK_RUN_ON(&x)` ≡ `RTC_DCHECK(x->IsCurrent())`，`RTC_DCHECK_IS_ON=0` 时是空操作。

## 4. 线程模型（完整时序）

```
getUserMedia(video)
  └─ RTCVideoDevice::Create → VcmCapturer(未启动)
  └─ capturer->StartCapture()
       └─ VcmCapturer::StartCapture
            └─ worker_thread_->BlockingCall([&]{ vcm_->StartCapture(capability_); })
                 └─ VideoCaptureDS::StartCapture   (T_w = webrtc worker 线程)
                      ├─ 构建 DirectShow 过滤器图
                      └─ _mediaControl->Run()       (T_w)
                           ├─ 图进入 Running, DirectShow 内部为 push 源起流线程
                           ├─ CaptureInputPin::OnFilterActivated()   (T_w)
                           │    └─ capture_checker_.Detach()
                           └─ 源 push 帧:
                                CaptureInputPin::Receive()            (流线程 T_s)
                                     └─ 首次: capture_checker_ 绑定到 T_s + 设线程名
                                     └─ 之后: 必须仍为 T_s, 否则 :735 崩溃
```

- **正常摄像头驱动**：DirectShow 流线程是单一固定线程 → 每次 Receive 同线程 → CHECK 通过。
- **OBS 虚拟摄像头 / screen-capture-recorder 类**：内部多个采集线程/线程池轮流 push → Receive 跨线程 → CHECK 崩。

## 5. 为什么 flutter-webrtc 不崩（重要，打破"上层有魔法"的猜测）

flutter-webrtc 的 getUserMedia 路径与 webrtc-c **逐行一致**（同一个 `RTCVideoDevice::Create` → `VcmCapturer` → `VideoCaptureDS`），没有任何上层规避。差异只在**打包的二进制**：

| | libwebrtc 构建 | RTC_DCHECK | 摄像头行为 |
|---|---|---|---|
| flutter-webrtc 官方/正常发布 | release（is_debug=false） | 编译掉 | 跨线程投递但**不检查** → 不崩 |
| webrtc-c 曾用 | **debug**（55MB，带 msvcp140d/ucrtbased） | 生效 | 跨线程投递 + 检查 → **崩** |

所以"flutter-webrtc 能、webrtc-c 崩"纯粹是 **debug vs release 构建差异**，不是代码差异。部署 libwebrtc.dll 前务必确认是 release 构建（约 20MB）。

## 6. 后续想仔细看时（TODO / 坑位）

1. **跨线程投递是否引起功能问题**：DCHECK 关掉后，`Receive()` 内的 `resulting_capability_` 读写注释声称"同一流线程独占 + 停流时主线程独占"，但实际来源跨线程时这个前提就不成立——只是暂时没出显性问题。若日后出现花屏/丢帧/竞态，需实测确认。
2. **上游正确修法**（chromium 侧）：`Receive()` 不该用 DCHECK 硬卡线程，要么去掉、要么把样本串行化到单一 webrtc 线程再喂 `VideoTrackSource`。改 libwebrtc 源码成本高，当前不值。
3. **替代路径**：真摄像头驱动单线程投递不会踩雷；若必须支持 OBS 虚拟摄像头且不想依赖 release 构建去掉检查，可考虑改默认设备选择/加一层线程串行器（在 webrtc-c 层包一层 sample 转发）。
4. **复现/验证**：`webrtc-cli/tool/repro_cam_mic.dart`——换 debug DLL 必崩、换 release DLL 不崩；完整验证跑 `test/testMain.dart`（摄像头段已启用）。
5. 相关线程坑（异步回调悬垂指针）见 [webrtc-c构建与测试.md](./webrtc-c构建与测试.md) 坑 6：C 回调栈上字符串 + Dart `NativeCallable.listener` 异步编组 → 必须堆拷贝。两个问题本质不同：一个是 **C→Dart 回调编组线程**，一个是 **DirectShow 内部投递线程**。
