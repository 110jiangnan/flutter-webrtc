# webrtc-cli

webrtc-c（`third_party/libwebrtc/webrtc-c`，封装 `libwebrtc.dll` 的 C ABI）的 **Dart FFI 绑定包**，仅服务 MyDesk 被控端。依赖 `webrtc_interface: ^1.3.0`，应用层用法与 flutter-webrtc 完全一致（两库可共存）。

> 架构/ABI 见 `docs/windowslinux迁移方案.md`、`docs/macos迁移方案.md`；编译命令、踩坑记录、验证方法见 `docs/webrtc-c构建与测试.md`。

## 测试运行

### 0. 先编译底层 DLL（Release）

```powershell
cd E:\game\MyDesk\MyDesk\flutter-webrtc\third_party\libwebrtc\webrtc-c
powershell -ExecutionPolicy Bypass -File win.ps1
```

产物：`build_vs\Release\webrtc_c.dll` + 同目录 `libwebrtc.dll`（加载器已自动查找，也可用环境变量 `WEBRTC_C_LIB` 指定）。

### 1. 综合测试（3 轮，约 4 分钟）

```bash
cd E:\game\MyDesk\MyDesk\flutter-webrtc\webrtc-cli
E:/home/flutter/flutter_windows_3.47.0-0.1.pre-beta/flutter/bin/cache/dart-sdk/bin/dart.exe test/testMain.dart
```

流程：A 发端采集（屏幕+麦克风+系统音频+DataChannel）→ B 收端 → SDP/ICE 交换 → DataChannel 双向收发 → 30s stats → 3 轮资源释放检查。通过标志：3 轮全过、`全部 3 轮测试完成`、进程正常退出（EXIT=0）、日志无 `Fatal`/`Check failed`。

### 2. 冒烟测试（快）

```bash
cd E:\game\MyDesk\MyDesk\flutter-webrtc\webrtc-cli
E:/home/flutter/flutter_windows_3.47.0-0.1.pre-beta/flutter/bin/cache/dart-sdk/bin/dart.exe tool/smoke.dart
```

覆盖 createPC / getUserMedia / getDisplayMedia / 桌面源 / 系统音频 / 能力查询 / 设备枚举，每步打印 `[OK]`。
