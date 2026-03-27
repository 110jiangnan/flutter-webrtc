#include "sys_audio_manager.h"
#include <iostream>
#include <sstream>
#include <iomanip>
#include <random>
#include <chrono>

namespace flutter_webrtc_plugin {

static std::string GenerateUUID() {
  std::random_device rd;
  std::mt19937_64 gen(rd());
  std::uniform_int_distribution<uint64_t> dist;
  
  auto uuid = dist(gen);
  std::stringstream ss;
  ss << std::hex << std::setfill('0');
  ss << std::setw(8) << (uuid >> 32) << '-';
  ss << std::setw(4) << ((uuid >> 16) & 0xFFFF) << '-';
  ss << std::setw(4) << (uuid & 0xFFFF) << '-';
  ss << std::setw(4) << ((uuid >> 48) & 0xFFFF) << '-';
  ss << std::setw(12) << (dist(gen) & 0xFFFFFFFFFFFFULL);
  
  return ss.str();
}

SysAudioManager* SysAudioManager::g_instance = nullptr;
std::mutex SysAudioManager::g_mutex;

SysAudioManager* SysAudioManager::GetInstance() {
  std::lock_guard<std::mutex> lock(g_mutex);
  
  if (!g_instance) {
    g_instance = new SysAudioManager();
  }
  
  return g_instance;
}

void SysAudioManager::DestroyInstance() {
  std::lock_guard<std::mutex> lock(g_mutex);
  
  if (g_instance) {
    g_instance->Release();
    delete g_instance;
    g_instance = nullptr;
  }
}

SysAudioManager::SysAudioManager()
    : audio_source_(nullptr),
      is_initialized_(false),
      is_capturing_(false),
      current_device_id_("") {
  std::cout << "SysAudioManager created" << std::endl;
}

SysAudioManager::~SysAudioManager() {
  std::cout << "SysAudioManager destroyed" << std::endl;
  Release();
}

bool SysAudioManager::Initialize(
    scoped_refptr<RTCPeerConnectionFactory> factory,
    const std::string& device_id) {
  
  if (!factory) {
    std::cout << "Invalid factory pointer" << std::endl;
    return false;
  }
  
  if (is_initialized_) {
    std::cout << "Already initialized" << std::endl;
    return true;
  }
  
  audio_source_ = new RefCountedObject<SysAudioSource>(factory, "sys_audio_capture");

  if (!audio_source_->rtc_audio_source()) {
    std::cout << "Failed to create sys audio source" << std::endl;
    return false;
  }

  // 鍒濆�鍖栭煶棰戞崟鑾峰櫒
  if (!audio_source_->Initialize(device_id)) {
    std::cout << "Failed to initialize audio capturer" << std::endl;
    audio_source_ = nullptr;
    return false;
  }
  if (!audio_source_->StartCapture()) {
    std::cout << "Failed to start audio capturer" << std::endl;
    audio_source_ = nullptr;
    return false;
  }

  current_device_id_ = device_id;
  is_initialized_ = true;

  std::cout << "SysAudioManager initialized with device: "
            << (device_id.empty() ? "default" : device_id) << std::endl;
  return true;
}

scoped_refptr<RTCMediaStream> SysAudioManager::CreateSysAudioMediaStream(
    scoped_refptr<RTCPeerConnectionFactory> factory,
    const std::string& stream_id) {
  
  if (!factory) {
    std::cout << "Invalid factory pointer" << std::endl;
    return nullptr;
  }
  
  if (!is_initialized_) {
    std::cout << "SysAudioManager not initialized" << std::endl;
    return nullptr;
  }
  
#if defined(_WIN32) || defined(WINDOWS)
  auto audio_track = CreateSysAudioTrack(factory, "");
  if (!audio_track) {
    std::cout << "Failed to create audio track" << std::endl;
    return nullptr;
  }
  std::string actual_stream_id = stream_id.empty() ?GenerateUUID() : stream_id;
  scoped_refptr<RTCMediaStream> stream =factory->CreateStream(actual_stream_id.c_str());
  
  if (!stream) {
    std::cout << "Failed to create media stream" << std::endl;
    return nullptr;
  }
  
  stream->AddTrack(audio_track);
  
  std::cout << "Created sys audio stream: " << actual_stream_id << std::endl;
  return stream;
#else
  std::cout << "System audio stream not available on this platform" << std::endl;
  return nullptr;
#endif
}

scoped_refptr<RTCAudioTrack> SysAudioManager::CreateSysAudioTrack(
    scoped_refptr<RTCPeerConnectionFactory> factory,
    const std::string& track_id) {
  
  if (!factory) {
    std::cout << "Invalid factory pointer";
    return nullptr;
  }
  
  if (!is_initialized_) {
    std::cout << "SysAudioManager not initialized";
    return nullptr;
  }
  
#if defined(_WIN32) || defined(WINDOWS)
  std::string actual_track_id = track_id.empty() ? GenerateUUID() : track_id;
  
  auto audio_track = factory->CreateAudioTrack(
      audio_source_->rtc_audio_source(), 
      actual_track_id.c_str());
  
  if (!audio_track) {
    std::cout << "Failed to create audio track" << std::endl;
    return nullptr;
  }
  
  std::cout << "Created sys audio track: " << actual_track_id << std::endl;
  
  return audio_track;
#else
  std::cout << "System audio track not available on this platform" << std::endl;
  return nullptr;
#endif
}

bool SysAudioManager::StartCapture() {
  if (!is_initialized_) {
    std::cout << "Not initialized" << std::endl;
    return false;
  }
  
  if (is_capturing_) {
    std::cout << "Already capturing" << std::endl;
    return true;
  }
  
#if defined(_WIN32) || defined(WINDOWS)
  if (audio_source_->StartCapture()) {
    is_capturing_ = true;
    std::cout << "Started system audio capture" << std::endl;
    return true;
  } else {
    std::cout << "Failed to start system audio capture" << std::endl;
    return false;
  }
#else
  std::cout << "System audio capture not available on this platform" << std::endl;
  return false;
#endif
}

void SysAudioManager::StopCapture() {
  if (!is_capturing_) {
    return;
  }
  
#if defined(_WIN32) || defined(WINDOWS)
  if (audio_source_) {
    audio_source_->StopCapture();
    is_capturing_ = false;
    std::cout << "Stopped system audio capture" << std::endl;
  }
#endif
}

bool SysAudioManager::IsCapturing() const {
  return is_capturing_;
}

bool SysAudioManager::IsInitialized() const {
  return is_initialized_;
}

std::map<std::string, std::string> SysAudioManager::GetRecordingDevices() {
  std::map<std::string, std::string> devices;
  
#if defined(_WIN32) || defined(WINDOWS)
  std::cout << "Getting recording devices" << std::endl;
#endif
  
  return devices;
}

bool SysAudioManager::SwitchDevice(const std::string& device_id) {
  if (!is_initialized_) {
    std::cout << "Not initialized" << std::endl;
    return false;
  }
  
  if (device_id == current_device_id_) {
    std::cout << "Same device, no need to switch" << std::endl;
    return true;
  }
  
  StopCapture();
  
  if (audio_source_) {
    audio_source_ = nullptr;
  }
  
  is_initialized_ = false;
  
  std::cout << "Device switching requires re-initialization" << std::endl;
  
  return true;
}

void SysAudioManager::EnablePcmRecording(bool enable, const std::string& file_path) {
#if defined(_WIN32) || defined(WINDOWS)
  if (audio_source_) {
    audio_source_->EnablePcmRecording(enable, file_path);
    std::cout << "PCM recording " << (enable ? "enabled" : "disabled") 
              << ": " << file_path << std::endl;
  } else {
    std::cout << "Cannot enable PCM recording - audio source not initialized" << std::endl;
  }
#else
  std::cout << "PCM recording not available on this platform" << std::endl;
#endif
}

void SysAudioManager::Release() {
  StopCapture();
  
#if defined(_WIN32) || defined(WINDOWS)
  if (audio_source_) {
    audio_source_ = nullptr;
  }
#endif
  
  is_initialized_ = false;
  is_capturing_ = false;
  current_device_id_ = "";
  
  std::cout << "SysAudioManager released" << std::endl;
}

}  // namespace flutter_webrtc_plugin

