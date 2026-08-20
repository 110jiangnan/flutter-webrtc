cmake_minimum_required(VERSION 3.29)
project(webrtc_c)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# libwebrtc 位置: webrtc-c 的上一级 (third_party/libwebrtc)
set(LIBWEBRTC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(LIBWEBRTC_INCLUDE "${LIBWEBRTC_DIR}/include")
set(LIBWEBRTC_LIBDIR "${LIBWEBRTC_DIR}/lib/win64")

# 三平台源文件分属三个目录, 互不复用:
#   win_linux/  C++ C ABI (封装 libwebrtc 内部 C++ API)   → win/linux 才编
#   mac/        ObjC C ABI (照抄 common/darwin 去 Flutter)  → apple 才编
#   common/     纯 std C++ 工具 (JSON/字符串/日期等, 不涉及平台) → 三平台都可编
# 绝不要把 win_linux 的 xx.cc 无条件 set 进 ALL 平台的源列表。
set(WEBRTC_C_SOURCES "")

# ---- 平台无关的纯 C++ 工具 (common/, 当前为空, 有实际共享代码时再往里放) ----
# 注: mac 用 ObjC + Foundation (NSJSONSerialization 等), 不消费 common 的 C++ 工具;
#     只有真正"三平台共用"的纯 std C++ 代码才放这, 别把单平台实现塞进来。
set(WEBRTC_COMMON_SOURCES "")

# ---- win/linux: C++ C ABI ----
if(WIN32 OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND WEBRTC_C_SOURCES
    win_linux/src/webrtc.cc
    win_linux/src/webrtc_common.cc
    win_linux/src/webrtc_base.cc
    win_linux/src/webrtc_media_stream.cc
    win_linux/src/webrtc_peerconnection.cc
    win_linux/src/webrtc_data_channel.cc
    win_linux/src/webrtc_screen_capture.cc
    win_linux/src/webrtc_sys_audio_manager.cc
    win_linux/src/webrtc_sys_audio_source.cc
    win_linux/src/webrtc_win_sys_audio_capturer.cc
  )
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(APPEND WEBRTC_C_SOURCES win_linux/src/webrtc_linux_sys_audio_capturer.cc)
  endif()
elseif(APPLE)
  # mac 独立整套 ObjC: 不复用 win/linux 的 C++ 源码
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
    mac/src/AudioManager.mm
  )
endif()

list(APPEND WEBRTC_C_SOURCES ${WEBRTC_COMMON_SOURCES})

add_library(webrtc_c SHARED ${WEBRTC_C_SOURCES})

# 头文件搜索路径: common/include + 各平台 include
target_include_directories(webrtc_c PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/common/include"
  "${LIBWEBRTC_INCLUDE}"
)
if(WIN32 OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_include_directories(webrtc_c PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/win_linux/include"
  )
elseif(APPLE)
  target_include_directories(webrtc_c PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src"
  )
endif()

# 导出我们自己的 C ABI (win 走 dllexport, mac/linux 走 visibility)
target_compile_definitions(webrtc_c PRIVATE WEBRTC_EXPORTS)
# 对齐桌面采集 vtable(GetDesktopDevice 在接口里)
target_compile_definitions(webrtc_c PRIVATE RTC_DESKTOP_DEVICE)

if(WIN32)
  # 消费 libwebrtc.dll: 头文件走 dllimport, 链接导入库 libwebrtc.dll.lib
  target_compile_definitions(webrtc_c PRIVATE LIB_WEBRTC_API_DLL)
  target_link_libraries(webrtc_c PRIVATE "${LIBWEBRTC_LIBDIR}/libwebrtc.dll.lib")
  # Windows 系统音频采集需要
  target_link_libraries(webrtc_c PRIVATE ole32 mmdevapi)
  # 运行时: 把 libwebrtc.dll 拷到 webrtc_c.dll 旁边, dart 加载时能一起找到
  add_custom_command(TARGET webrtc_c POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${LIBWEBRTC_LIBDIR}/libwebrtc.dll"
            "$<TARGET_FILE_DIR:webrtc_c>"
  )
elseif(APPLE)
  # macOS: 链接 WebRTC.xcframework (路径可用 -DWEBRTC_MAC_FRAMEWORK= 覆盖)
  set(WEBRTC_MAC_FRAMEWORK
      "${WEBRTC_MAC_FRAMEWORK}")
  if(NOT WEBRTC_MAC_FRAMEWORK)
    set(WEBRTC_MAC_FRAMEWORK
        "${LIBWEBRTC_DIR}/WebRTC.xcframework/macos-arm64_x86_64/WebRTC.framework/WebRTC")
  endif()
  target_link_libraries(webrtc_c PRIVATE
    "${WEBRTC_MAC_FRAMEWORK}"
    "-framework CoreFoundation -framework Foundation"
    "-framework CoreAudio -framework AudioToolbox"
    "-framework AVFoundation -framework CoreMedia"
    "-framework CoreGraphics -framework CoreVideo"
    "-framework ScreenCaptureKit"
    "-framework AppKit"
  )
  # .mm 源用 OBJCXX 编译 (ObjC + C++ bridging, ScreenCaptureKit 等 ObjC 接口)
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

# 中文注释需要 /utf-8 (MSVC)
if(MSVC)
  target_compile_options(webrtc_c PRIVATE /utf-8)
endif()
