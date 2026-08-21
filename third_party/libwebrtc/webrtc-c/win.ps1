# ============================================================
# webrtc-c (webrtc_cli 的 FFI 底层 DLL) — Windows Release 完整编译命令
#
# 硬约束(踩坑警告):
#   - libwebrtc.dll 是 MSVC/clang-cl 构建的, 只能 MSVC 编译;
#     MinGW(gcc/g++)链接会报 __imp_... undefined, 永远链不动
#   - cmake 版本必须 >= 3.29 (用 Qt 自带的 3.30.5; PATH 里 3.26 不够)
#   - CMakeLists 已定义 RTC_DESKTOP_DEVICE(对齐桌面采集 vtable) +
#     LIB_WEBRTC_API_DLL / WEBRTC_EXPORTS, 无需在命令行重复
#
# 依赖:  VS2022 Community (C++ 桌面开发负载)
# 输出:  build_vs\Release\webrtc_c.dll + 同目录自动拷贝 libwebrtc.dll
#
# 用法:  powershell -ExecutionPolicy Bypass -File win.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

# git-bash 里跑 powershell 时会继承 _CL_ 环境变量, 会破坏 cl 的 /D 参数, 清掉
Remove-Item Env:_CL_ -ErrorAction SilentlyContinue

$cmake    = 'E:\home\qt\Tools\CMake_64\bin\cmake.exe'
$buildDir = 'build_vs'   # 与 Debug 共用同一个 VS 工程, Release 产物进 build_vs\Release

if (-not (Test-Path $cmake)) {
    Write-Error "找不到 cmake: $cmake (请确认 Qt 安装路径)"
}

Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
try {
    # 1) 配置(幂等: build_vs 已存在则直接沿用)
    & $cmake -S . -B $buildDir -G "Visual Studio 17 2022" -A x64
    if ($LASTEXITCODE -ne 0) { throw "cmake 配置失败" }

    # 2) Release 编译
    & $cmake --build $buildDir --config Release
    if ($LASTEXITCODE -ne 0) { throw "编译失败" }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "完成: $buildDir\Release\webrtc_c.dll (同目录已带 libwebrtc.dll)"
Write-Host "Dart 侧 webrtc-cli 会自动尝试 build_vs\Release; 也可用环境变量 WEBRTC_C_LIB 指定路径"