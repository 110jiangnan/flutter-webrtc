cmake_minimum_required(VERSION 3.29)
project(webrtc_c)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# libwebrtc 位置: webrtc-c 的上一级 (third_party/libwebrtc)
set(LIBWEBRTC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(LIBWEBRTC_INCLUDE "${LIBWEBRTC_DIR}/include")
set(LIBWEBRTC_LIBDIR "${LIBWEBRTC_DIR}/lib/win64")

set(WEBRTC_C_SOURCES
  src/webrtc.cc
  src/webrtc_common.cc
  src/webrtc_base.cc
  src/webrtc_media_stream.cc
  src/webrtc_peerconnection.cc
  src/webrtc_data_channel.cc
  src/webrtc_screen_capture.cc
  src/webrtc_sys_audio_manager.cc
  src/webrtc_sys_audio_source.cc
  src/webrtc_win_sys_audio_capturer.cc
)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND WEBRTC_C_SOURCES src/webrtc_linux_sys_audio_capturer.cc)
endif()

add_library(webrtc_c SHARED ${WEBRTC_C_SOURCES})

# 本项目头文件 include/ + libwebrtc 头文件
target_include_directories(webrtc_c PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${LIBWEBRTC_INCLUDE}"
)

# 消费 libwebrtc.dll: 头文件走 dllimport, 链接导入库 libwebrtc.dll.lib
target_compile_definitions(webrtc_c PRIVATE LIB_WEBRTC_API_DLL)
# 导出我们自己的 C ABI (dllexport)
target_compile_definitions(webrtc_c PRIVATE WEBRTC_EXPORTS)
# 对齐 DLL 构建的桌面采集 vtable(GetDesktopDevice 在接口里)
target_compile_definitions(webrtc_c PRIVATE RTC_DESKTOP_DEVICE)
target_link_libraries(webrtc_c PRIVATE "${LIBWEBRTC_LIBDIR}/libwebrtc.dll.lib")

# Windows 系统音频采集需要
if(WIN32)
  target_link_libraries(webrtc_c PRIVATE ole32 mmdevapi)
endif()

# 中文注释需要 /utf-8 (MSVC)
if(MSVC)
  target_compile_options(webrtc_c PRIVATE /utf-8)
endif()

# 运行时: 把 libwebrtc.dll 拷到 webrtc_c.dll 旁边, dart 加载时能一起找到
add_custom_command(TARGET webrtc_c POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${LIBWEBRTC_LIBDIR}/libwebrtc.dll"
          "$<TARGET_FILE_DIR:webrtc_c>"
)
