# common/ — 三平台共用的纯 C++ 工具

本目录只放**真正三平台共用**、**不涉及平台**、**纯 std C++/C** 的工具类（JSON 序列化/反序列化、日期、字符串工具等）。

## 放置规则

- **必须**是纯标准库/自研 C++（`<string>`/`<vector>`/`<chrono>` 等），不能依赖平台 API、不能依赖 libwebrtc。
- 只放**三个平台都在用**的代码。**单平台实现不要塞进来**：
  - win/linux 的 `win_linux/webrtc_common.cc`（JNode JSON）虽同为 C++，但 mac 的 ObjC 用 Foundation 的 `NSJSONSerialization`，并不消费它 —— 所以 JNode **留在 win_linux，不进 common**。
  - 若将来某段纯 std 工具确实被 win/linux 与 mac（ObjC++ 亦可 include C++ 头）三方共用，再挪到这里。

## CMake 接线

`CMakeLists.txt` 里 `WEBRTC_COMMON_SOURCES` 会追加到 `WEBRTC_C_SOURCES`，`common/include` 已加入 include 路径，三平台都能看到本目录头文件。往这里加文件时同步更新该变量。
