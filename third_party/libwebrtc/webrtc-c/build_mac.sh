#!/usr/bin/env bash
# ============================================================
# webrtc-c (webrtc_cli 的 FFI 底层动态库) — macOS Universal 编译脚本
#
# 产物:
#   build_mac/dist/libwebrtc_c.dylib   (arm64 + x86_64 通用二进制)
#   build_mac/dist/WebRTC.framework     (与 dylib 同目录, @loader_path 解析)
#   默认再拷一份到 <repo>/webrtc-cli/native/  (项目 native 库目录)
#
# 硬约束(踩坑警告):
#   - cmake >= 3.29 (CMakeLists 硬性要求; 本机没有则尝试 brew install cmake)
#   - 需要 WebRTC.xcframework 的 macos-arm64_x86_64 切片(必须同时含 arm64 + x86_64)
#   - RTC_DESKTOP_DEVICE / WEBRTC_EXPORTS 已由 CMakeLists 全局定义, 命令行不要重复
#   - mac 源是 ObjC(.mm), 需要 -F<切片目录> 才能 #import <WebRTC/...>
#     (CMakeLists 没加框架搜索路径, 这里用 CMAKE_*_FLAGS 补上)
#
# 用法:
#   ./build_mac.sh                                   # 默认: 构建 + 部署到 webrtc-cli
#   WEBRTC_XCFRAMEWORK=<路径> ./build_mac.sh         # 指定 xcframework
#   MACOS_DEPLOYMENT_TARGET=10.15 ./build_mac.sh     # 覆盖最低系统版本(默认 10.15)
#   ./build_mac.sh --no-deploy                       # 只构建到 build_mac/dist, 不部署
#   ./build_mac.sh --no-install-cmake                # cmake 缺失时报错, 不 brew 安装
#   ./build_mac.sh -h                                # 帮助
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEPLOY=1
INSTALL_CMAKE=1
for arg in "$@"; do
  case "$arg" in
    --no-deploy)        DEPLOY=0 ;;
    --no-install-cmake) INSTALL_CMAKE=0 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed 's/^==.*//' | sed '/^$/d'
      exit 0 ;;
    *) echo "未知参数: $arg (见 ./build_mac.sh -h)" >&2; exit 1 ;;
  esac
done

LIBWEBRTC_DIR="${SCRIPT_DIR}/.."           # third_party/libwebrtc
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CLI_DIR="${REPO_ROOT}/webrtc-cli"
BUILD_DIR="build_mac"
OUT_DIR="${BUILD_DIR}/dist"

MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-10.15}"

log()  { printf '\033[1;32m[build-mac]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build-mac]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build-mac] 错误: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0) 定位 WebRTC.xcframework (macos-arm64_x86_64 切片) -------------------
find_xcframework() {
  local cand
  if [[ -n "${WEBRTC_XCFRAMEWORK:-}" && -d "${WEBRTC_XCFRAMEWORK}" ]]; then
    printf '%s' "${WEBRTC_XCFRAMEWORK}"; return
  fi
  # 优先级: 环境变量 WEBRTC_XCFRAMEWORK -> 本机已知部署位置
  for cand in \
    "${HOME}/Desktop/zjn/deploy/Specs/WebRTC.xcframework"; do
    if [[ -d "${cand}/macos-arm64_x86_64/WebRTC.framework" ]]; then
      printf '%s' "${cand}"; return
    fi
  done
  printf '%s' ""
}

XCFW="$(find_xcframework)"
if [[ -z "${XCFW}" ]]; then
  die "找不到 WebRTC.xcframework。用 WEBRTC_XCFRAMEWORK=<路径> 指定, 或放在:
       ${HOME}/Desktop/zjn/deploy/Specs/WebRTC.xcframework"
fi
SLICE="${XCFW}/macos-arm64_x86_64"
FRAMEWORK_BIN="${SLICE}/WebRTC.framework/WebRTC"
[[ -f "${FRAMEWORK_BIN}" ]] || die "切片不完整: 缺少 ${FRAMEWORK_BIN}"
log "WebRTC.xcframework: ${XCFW}"
log "切片: ${SLICE}"

ARCH_INFO="$(lipo -info "${FRAMEWORK_BIN}")"
log "框架架构: ${ARCH_INFO}"
echo "${ARCH_INFO}" | grep -q 'arm64' || warn "框架缺 arm64 切片, 最终 dylib 不会是真通用包"
echo "${ARCH_INFO}" | grep -q 'x86_64' || warn "框架缺 x86_64 切片"

# ---- 1) cmake 检查 (>= 3.29) -------------------------------------------------
if ! command -v cmake >/dev/null 2>&1; then
  if [[ "${INSTALL_CMAKE}" == 1 ]] && command -v brew >/dev/null 2>&1; then
    log "未找到 cmake, 用 brew 安装 ..."
    brew install cmake
  else
    die "未找到 cmake (需要 >= 3.29)。请先 'brew install cmake' 或装 cmake.org 的 CMake.app"
  fi
fi
CMAKE_MAJOR="$(cmake --version | head -1 | sed -E 's/.*cmake version ([0-9]+)\.([0-9]+).*/\1/')"
CMAKE_MINOR="$(cmake --version | head -1 | sed -E 's/.*cmake version ([0-9]+)\.([0-9]+).*/\2/')"
if (( CMAKE_MAJOR < 3 )) || (( CMAKE_MAJOR == 3 && CMAKE_MINOR < 29 )); then
  die "cmake 版本太低: $(cmake --version | head -1) (需要 >= 3.29)"
fi
log "$(cmake --version | head -1)"

# ---- 2) cmake 配置 (Universal: arm64 + x86_64) ------------------------------
log "配置 cmake (${MACOS_DEPLOYMENT_TARGET} / arm64;x86_64) ..."
cmake -S . -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}" \
  -DCMAKE_C_FLAGS="-F${SLICE}" \
  -DCMAKE_CXX_FLAGS="-F${SLICE}" \
  -DCMAKE_OBJCXX_FLAGS="-F${SLICE}" \
  -DWEBRTC_MAC_FRAMEWORK="${FRAMEWORK_BIN}"

# ---- 3) 编译 ----------------------------------------------------------------
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
log "编译 (${JOBS} 线程) ..."
cmake --build "${BUILD_DIR}" -- -j "${JOBS}"

# ---- 4) 后处理: 输出到 dist/, 可重定位 + 同目录 WebRTC.framework ------------
log "后处理 -> ${OUT_DIR} ..."
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

cp "${BUILD_DIR}/libwebrtc_c.dylib" "${OUT_DIR}/libwebrtc_c.dylib"
cp -R "${SLICE}/WebRTC.framework"   "${OUT_DIR}/WebRTC.framework"

# install name 改成 @rpath, 可整体移动部署 (dart dlopen 按名字找)
install_name_tool -id "@rpath/libwebrtc_c.dylib" "${OUT_DIR}/libwebrtc_c.dylib"
# 两个 rpath: @loader_path(dev/测试, 同目录放 WebRTC.framework) +
#           @executable_path/../Frameworks(App bundle, WebRTC.framework 在 Contents/Frameworks/)
if ! otool -l "${OUT_DIR}/libwebrtc_c.dylib" | grep -q '@loader_path'; then
  install_name_tool -add_rpath "@loader_path" "${OUT_DIR}/libwebrtc_c.dylib"
fi
if ! otool -l "${OUT_DIR}/libwebrtc_c.dylib" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${OUT_DIR}/libwebrtc_c.dylib"
fi
# 本地测试: 直接用 xcframework 切片目录的绝对路径
if ! otool -l "${OUT_DIR}/libwebrtc_c.dylib" | grep -q "${SLICE}"; then
  install_name_tool -add_rpath "${SLICE}" "${OUT_DIR}/libwebrtc_c.dylib"
fi
# 改过二进制后重新 ad-hoc 签名 (Apple Silicon 上未签名/签名失效会加载失败)
if command -v codesign >/dev/null 2>&1; then
  codesign --force -s - "${OUT_DIR}/libwebrtc_c.dylib" 2>/dev/null || warn "ad-hoc 签名失败(非致命)"
fi

# ---- 5) 验证 ----------------------------------------------------------------
log "验证产物架构:"
lipo -info "${OUT_DIR}/libwebrtc_c.dylib"
echo "${ARCH_INFO}" | grep -q 'arm64' && \
  lipo -info "${OUT_DIR}/libwebrtc_c.dylib" | grep -q 'arm64' || \
  die "dylib 缺 arm64 切片!"
lipo -info "${OUT_DIR}/libwebrtc_c.dylib" | grep -q 'x86_64' || \
  die "dylib 缺 x86_64 切片!"

log "依赖 (WebRTC 应为 @rpath/WebRTC.framework/WebRTC):"
otool -L "${OUT_DIR}/libwebrtc_c.dylib"

# ---- 6) 部署到 webrtc-cli (dart FFI 候选路径) ------------------------------
if [[ "${DEPLOY}" == 1 ]]; then
  if [[ -d "${CLI_DIR}" ]]; then
    DEPLOY_DIR="${CLI_DIR}/native"
    mkdir -p "${DEPLOY_DIR}"
    cp "${OUT_DIR}/libwebrtc_c.dylib" "${DEPLOY_DIR}/libwebrtc_c.dylib"
    # WebRTC.framework 不拷到这里: App 运行时走 @executable_path/../Frameworks/
    log "已部署 -> ${DEPLOY_DIR}/libwebrtc_c.dylib"
  else
    warn "未找到 ${CLI_DIR}, 跳过部署 (可用 WEBRTC_C_LIB 环境变量指定 dylib 路径)"
  fi
fi

echo ""
echo "============================================================"
echo "完成: ${OUT_DIR}/libwebrtc_c.dylib (arm64 + x86_64)"
echo "      WebRTC.framework 已放同目录, 整体移动即可用"
if [[ "${DEPLOY}" == 1 && -d "${CLI_DIR}" ]]; then
  echo "      webrtc-cli 侧: ${CLI_DIR}/native/libwebrtc_c.dylib"
  echo "      (或 export WEBRTC_C_LIB=${OUT_DIR}/libwebrtc_c.dylib)"
fi
echo "============================================================"
