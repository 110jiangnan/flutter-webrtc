#if defined(__linux__)

#include "loopback_capturer.h"

// Linux factory for LoopbackCapturer.
//
// When built with libpulse (HAVE_LIBPULSE, see CMakeLists) this returns the
// PulseAudio monitor-capture implementation (pulse_loopback_capturer.cc) so
// that getDisplayMedia({audio: true}) streams system audio. Without libpulse
// the build still succeeds and this returns nullptr (getDisplayMedia
// continues without an audio track), mirroring upstream linux/CMakeLists.txt.
//
// The declaration in loopback_capturer.h is non-inline for __linux__, so this
// translation unit must always define the symbol.

#if defined(HAVE_LIBPULSE)
#include "pulse_loopback_capturer.h"
#endif

namespace flutter_webrtc_plugin {

#if defined(HAVE_LIBPULSE)

std::unique_ptr<LoopbackCapturer> CreateLoopbackCapturer(
    const std::string& source_id) {
  return std::unique_ptr<LoopbackCapturer>(
      new PulseLoopbackCapturer(source_id));
}

#else  // libpulse not available: preserve the nullptr behaviour.

std::unique_ptr<LoopbackCapturer> CreateLoopbackCapturer(
    const std::string& /*source_id*/) {
  return nullptr;
}

#endif

}  // namespace flutter_webrtc_plugin

#endif  // __linux__
