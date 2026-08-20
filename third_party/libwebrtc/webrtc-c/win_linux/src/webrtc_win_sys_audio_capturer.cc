// webrtc_win_sys_audio_capturer.cc — WASAPI loopback 系统音频采集(参考 win_sys_audio_capturer.cc)

#include "webrtc_win_sys_audio_capturer.h"

#include <functiondiscoverykeys_devpkey.h>
#include <iostream>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "mmdevapi.lib")

namespace webrtc {

static std::wstring StringToWideString(const std::string& str) {
  int size_needed =
      MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, nullptr, 0);
  std::wstring wstr(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &wstr[0], size_needed);
  return wstr;
}

static std::string WideStringToString(const std::wstring& wstr) {
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, nullptr,
                                        0, nullptr, nullptr);
  std::string str(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, &str[0], size_needed,
                      nullptr, nullptr);
  return str;
}

WebrtcWinSysAudioCapturer::WebrtcWinSysAudioCapturer() {}

WebrtcWinSysAudioCapturer::~WebrtcWinSysAudioCapturer() {
  StopCapture();
  Release();
}

bool WebrtcWinSysAudioCapturer::Initialize(const std::string& device_id) {
  HRESULT hr;

  hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
    std::cout << "Failed to initialize COM: " << hr << std::endl;
    return false;
  }
  // RPC_E_CHANGED_MODE: 线程已按其它模型(MTA)初始化 COM, 直接复用, 不重复初始化
  com_initialized_ = SUCCEEDED(hr);

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&device_enumerator_));
  if (FAILED(hr)) {
    std::cout << "Failed to create device enumerator: " << hr << std::endl;
    CleanupCOM();
    return false;
  }

  if (device_id.empty()) {
    hr = device_enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
  } else {
    std::wstring wide_device_id = StringToWideString(device_id);
    hr = device_enumerator_->GetDevice(wide_device_id.c_str(), &device_);
  }
  if (FAILED(hr)) {
    std::cout << "Failed to get audio endpoint: " << hr
              << ", trying default render device instead" << std::endl;
    hr = device_enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
    if (FAILED(hr)) {
      CleanupCOM();
      return false;
    }
  }

  hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                         reinterpret_cast<void**>(&audio_client_));
  if (FAILED(hr)) {
    std::cout << "Failed to activate audio client: " << hr << std::endl;
    CleanupCOM();
    return false;
  }

  hr = audio_client_->GetMixFormat(&wave_format_);
  if (FAILED(hr)) {
    std::cout << "Failed to get mix format: " << hr << std::endl;
    CleanupCOM();
    return false;
  }

  // 从优先频率/声道组合里挑一个系统支持的, 统一为 16bit PCM
  WAVEFORMATEXTENSIBLE Wfx = WAVEFORMATEXTENSIBLE();
  WAVEFORMATEX* pWfxClosestMatch = NULL;
  Wfx.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  Wfx.Format.wBitsPerSample = 16;
  Wfx.Format.cbSize = 22;
  Wfx.dwChannelMask = 0;
  Wfx.Samples.wValidBitsPerSample = Wfx.Format.wBitsPerSample;
  Wfx.SubFormat = KSDATAFORMAT_SUBTYPE_PCM;

  const int freqs[6] = {48000, 44100, 16000, 96000, 32000, 8000};
  hr = S_FALSE;
  for (unsigned int freq = 0; freq < sizeof(freqs) / sizeof(freqs[0]); freq++) {
    for (unsigned int chan = 0;
         chan < sizeof(_recChannelsPrioList) / sizeof(_recChannelsPrioList[0]);
         chan++) {
      Wfx.Format.nChannels = _recChannelsPrioList[chan];
      Wfx.Format.nSamplesPerSec = freqs[freq];
      Wfx.Format.nBlockAlign =
          Wfx.Format.nChannels * Wfx.Format.wBitsPerSample / 8;
      Wfx.Format.nAvgBytesPerSec =
          Wfx.Format.nSamplesPerSec * Wfx.Format.nBlockAlign;
      hr = audio_client_->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED,
                                            (WAVEFORMATEX*)&Wfx,
                                            &pWfxClosestMatch);
      if (hr == S_OK) {
        break;
      } else {
        if (pWfxClosestMatch) {
          std::cout << "nChannels=" << Wfx.Format.nChannels
                    << ", nSamplesPerSec=" << Wfx.Format.nSamplesPerSec
                    << " not supported. Closest: nChannels="
                    << pWfxClosestMatch->nChannels << ", nSamplesPerSec="
                    << pWfxClosestMatch->nSamplesPerSec << std::endl;
          CoTaskMemFree(pWfxClosestMatch);
          pWfxClosestMatch = NULL;
        } else {
          std::cout << "nChannels=" << Wfx.Format.nChannels
                    << ", nSamplesPerSec=" << Wfx.Format.nSamplesPerSec
                    << " not supported. No closest match." << std::endl;
        }
      }
    }
    if (hr == S_OK) break;
  }
  CoTaskMemFree(pWfxClosestMatch);
  if (FAILED(hr)) {
    std::cout << "fail to set audio format to webrtc: " << hr << std::endl;
    CleanupCOM();
    return false;
  }

  std::cout << "set Audio format - SampleRate: " << Wfx.Format.nSamplesPerSec
            << ", Channels: " << Wfx.Format.nChannels
            << ", BitsPerSample: " << Wfx.Format.wBitsPerSample << std::endl;

  preferred_sample_rate_ = Wfx.Format.nSamplesPerSec;
  preferred_bits_per_sample_ = Wfx.Format.wBitsPerSample;
  preferred_channels_ = Wfx.Format.nChannels;

  hr = audio_client_->Initialize(
      AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 100000, 0,
      (WAVEFORMATEX*)&Wfx, nullptr);
  if (FAILED(hr)) {
    std::cout << "Failed to initialize audio client with LOOPBACK mode: " << hr
              << std::endl;
    CleanupCOM();
    return false;
  }

  hr = audio_client_->GetBufferSize(&buffer_frame_count_);
  if (FAILED(hr)) {
    std::cout << "Failed to get buffer size: " << hr << std::endl;
    CleanupCOM();
    return false;
  }

  hr = audio_client_->GetService(__uuidof(IAudioCaptureClient),
                                 reinterpret_cast<void**>(&capture_client_));
  if (FAILED(hr)) {
    std::cout << "Failed to get capture client: " << hr << std::endl;
    CleanupCOM();
    return false;
  }

  std::cout << "WinSysAudioCapturer initialized successfully" << std::endl;
  return true;
}

bool WebrtcWinSysAudioCapturer::StartCapture() {
  if (is_capturing_) return false;
  if (!audio_client_ || !capture_client_) return false;

  should_stop_ = false;
  HRESULT hr = audio_client_->Start();
  if (FAILED(hr)) {
    std::cout << "Failed to start audio client: " << hr << std::endl;
    return false;
  }
  is_capturing_ = true;
  capture_thread_ = std::thread(&WebrtcWinSysAudioCapturer::CaptureThread, this);
  return true;
}

void WebrtcWinSysAudioCapturer::StopCapture() {
  if (!is_capturing_) return;
  should_stop_ = true;
  is_capturing_ = false;
  if (capture_thread_.joinable()) capture_thread_.join();
  if (audio_client_) audio_client_->Stop();
}

void WebrtcWinSysAudioCapturer::Release() {
  StopCapture();
  if (capture_client_) {
    capture_client_->Release();
    capture_client_ = nullptr;
  }
  if (audio_client_) {
    audio_client_->Release();
    audio_client_ = nullptr;
  }
  if (device_) {
    device_->Release();
    device_ = nullptr;
  }
  if (device_enumerator_) {
    device_enumerator_->Release();
    device_enumerator_ = nullptr;
  }
  if (wave_format_) {
    CoTaskMemFree(wave_format_);
    wave_format_ = nullptr;
  }
  CleanupCOM();
}

void WebrtcWinSysAudioCapturer::SetCallback(AudioDataCallback callback,
                                            void* user_data) {
  std::lock_guard<std::mutex> lock(mutex_);
  callback_ = callback;
  user_data_ = user_data;
}

void WebrtcWinSysAudioCapturer::CaptureThread() {
  while (!should_stop_) {
    UINT32 num_frames_available = 0;
    HRESULT hr = capture_client_->GetNextPacketSize(&num_frames_available);
    if (FAILED(hr)) break;

    while (num_frames_available > 0 && !should_stop_) {
      BYTE* data = nullptr;
      UINT32 num_frames_to_read = 0;
      hr = capture_client_->GetBuffer(&data, &num_frames_to_read, &flags_,
                                      nullptr, nullptr);
      if (FAILED(hr)) break;

      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (callback_) {
          callback_(data, preferred_bits_per_sample_, preferred_sample_rate_,
                    preferred_channels_, num_frames_to_read, user_data_);
        }
      }

      hr = capture_client_->ReleaseBuffer(num_frames_to_read);
      if (FAILED(hr)) break;
      hr = capture_client_->GetNextPacketSize(&num_frames_available);
      if (FAILED(hr)) break;
    }
    Sleep(5);
  }
}

std::vector<std::pair<std::string, std::string>>
WebrtcWinSysAudioCapturer::GetRecordingDevices() {
  std::vector<std::pair<std::string, std::string>> devices;

  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) return devices;

  IMMDeviceCollection* collection = nullptr;
  hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection);
  if (FAILED(hr)) {
    enumerator->Release();
    return devices;
  }

  UINT count = 0;
  hr = collection->GetCount(&count);
  if (SUCCEEDED(hr)) {
    for (UINT i = 0; i < count; i++) {
      IMMDevice* device = nullptr;
      hr = collection->Item(i, &device);
      if (SUCCEEDED(hr)) {
        LPWSTR id = nullptr;
        hr = device->GetId(&id);
        if (SUCCEEDED(hr)) {
          std::wstring wide_id(id);
          std::string device_id = WideStringToString(wide_id);

          IPropertyStore* props = nullptr;
          hr = device->OpenPropertyStore(STGM_READ, &props);
          if (SUCCEEDED(hr)) {
            PROPVARIANT name;
            PropVariantInit(&name);
            hr = props->GetValue(PKEY_Device_FriendlyName, &name);
            if (SUCCEEDED(hr)) {
              std::wstring wide_name(name.pwszVal);
              std::string device_name = WideStringToString(wide_name);
              devices.push_back({device_id, device_name});
              PropVariantClear(&name);
            }
            props->Release();
          }
          CoTaskMemFree(id);
        }
        device->Release();
      }
    }
  }

  collection->Release();
  enumerator->Release();
  return devices;
}

void WebrtcWinSysAudioCapturer::CleanupCOM() {
  if (com_initialized_) {
    CoUninitialize();
    com_initialized_ = false;
  }
}

bool WebrtcWinSysAudioCapturer::IsSystemAudioCaptureSupported() { return true; }

}  // namespace webrtc
