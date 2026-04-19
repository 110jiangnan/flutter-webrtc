// Windows System Audio Capturer Implementation
// Windows platform only

#include "win_sys_audio_capturer.h"
#include <iostream>
#include <functiondiscoverykeys_devpkey.h>
#include <Audioclient.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "mmdevapi.lib")

namespace flutter_webrtc_plugin {

static std::wstring StringToWideString(const std::string& str) {
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, nullptr, 0);
  std::wstring wstr(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &wstr[0], size_needed);
  return wstr;
}

static std::string WideStringToString(const std::wstring& wstr) {
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string str(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, &str[0], size_needed, nullptr, nullptr);
  return str;
}

WinSysAudioCapturer::WinSysAudioCapturer() {
  std::cout << "WinSysAudioCapturer created";
}

WinSysAudioCapturer::~WinSysAudioCapturer() {
  StopCapture();
  Release();
  std::cout << "WinSysAudioCapturer destroyed" << std::endl;
}

bool WinSysAudioCapturer::Initialize(const std::string& device_id) {
  HRESULT hr;
  
  hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(hr)) {
    std::cout << "Failed to initialize COM: " << hr << std::endl;
    return false;
  }

  hr = CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
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
    std::cout << "Failed to get audio endpoint: " << hr << std::endl;
    std::cout << "Trying to get default capture device instead" << std::endl;
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

  // Iterate over frequencies and channels, in order of priority
  for (unsigned int freq = 0; freq < sizeof(freqs) / sizeof(freqs[0]); freq++) {
    for (unsigned int chan = 0; chan < sizeof(_recChannelsPrioList) / sizeof(_recChannelsPrioList[0]); chan++) {
      Wfx.Format.nChannels = _recChannelsPrioList[chan];
      Wfx.Format.nSamplesPerSec = freqs[freq];
      Wfx.Format.nBlockAlign =
          Wfx.Format.nChannels * Wfx.Format.wBitsPerSample / 8;
      Wfx.Format.nAvgBytesPerSec =
          Wfx.Format.nSamplesPerSec * Wfx.Format.nBlockAlign;
      hr = audio_client_->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, (WAVEFORMATEX*)&Wfx, &pWfxClosestMatch);
      if (hr == S_OK) {
        break;
      } else {
        if (pWfxClosestMatch) {
          std::cout << "nChannels=" << Wfx.Format.nChannels
                    << ", nSamplesPerSec=" << Wfx.Format.nSamplesPerSec
                    << " is not supported. Closest match: "
                       "nChannels="
                    << pWfxClosestMatch->nChannels << ", nSamplesPerSec="
                    << pWfxClosestMatch->nSamplesPerSec << std::endl;
          CoTaskMemFree(pWfxClosestMatch);
          pWfxClosestMatch = NULL;
        } else {
          std::cout << "nChannels=" << Wfx.Format.nChannels
                    << ", nSamplesPerSec=" << Wfx.Format.nSamplesPerSec
                    << " is not supported. No closest match." << std::endl;
        }
      }
    }
    if (hr == S_OK)
      break;
  }
  CoTaskMemFree(pWfxClosestMatch);
  if (FAILED(hr)) {
    std::cout << "fail to set audio format to webrtc" << hr << std::endl;
    CleanupCOM();
    return false;
  }

  std::cout << "window default Audio format - SampleRate: " << wave_format_->nSamplesPerSec
                   << ", Channels: " << wave_format_->nChannels
                   << ", BitsPerSample: " << wave_format_->wBitsPerSample << std::endl;
  std::cout << "set Audio format - SampleRate: " << Wfx.Format.nSamplesPerSec
            << ", Channels: " << Wfx.Format.nChannels
            << ", BitsPerSample: " << Wfx.Format.wBitsPerSample << std::endl;

  preferred_sample_rate_ = Wfx.Format.nSamplesPerSec;
  preferred_bits_per_sample_ = Wfx.Format.wBitsPerSample;
  preferred_channels_ = Wfx.Format.nChannels;
  hr = audio_client_->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK,
      100000, 0, (WAVEFORMATEX*)&Wfx, nullptr);
  
  if (FAILED(hr)) {
    std::cout << "Failed to initialize audio client with LOOPBACK mode: " << hr << std::endl;
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

bool WinSysAudioCapturer::StartCapture() {
  if (is_capturing_) {
    std::cout << "Already capturing" << std::endl;
    return false;
  }

  if (!audio_client_ || !capture_client_) {
    std::cout << "Not initialized" << std::endl;
    return false;
  }
  should_stop_ = false;
  
  HRESULT hr = audio_client_->Start();
  if (FAILED(hr)) {
    std::cout << "Failed to start audio client: " << hr << std::endl;
    return false;
  }
  is_capturing_ = true;
  capture_thread_ = std::thread(&WinSysAudioCapturer::CaptureThread, this);
  
  std::cout << "Started audio capture" << std::endl;
  return true;
}

void WinSysAudioCapturer::StopCapture() {
  if (!is_capturing_) {
    return;
  }

  should_stop_ = true;
  is_capturing_ = false;

  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }

  if (audio_client_) {
    audio_client_->Stop();
  }

  std::cout << "Stopped audio capture" << std::endl;
}

void WinSysAudioCapturer::Release() {
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

void WinSysAudioCapturer::SetCallback(AudioDataCallback callback, void* user_data) {
  std::lock_guard<std::mutex> lock(mutex_);
  callback_ = callback;
  user_data_ = user_data;
}

void WinSysAudioCapturer::CaptureThread() {
  std::cout << "Capture thread started" << std::endl;
  
  while (!should_stop_) {
    UINT32 num_frames_available = 0;
    HRESULT hr = capture_client_->GetNextPacketSize(&num_frames_available);
    
    if (FAILED(hr)) {
      std::cout << "Failed to get next packet size: " << hr;
      break;
    }

    while (num_frames_available > 0 && !should_stop_) {
      BYTE* data = nullptr;
      UINT32 num_frames_to_read = 0;
      
      hr = capture_client_->GetBuffer(&data, &num_frames_to_read,
                                      &flags_, nullptr, nullptr);
      
      if (FAILED(hr)) {
        std::cout << "Failed to get buffer: " << hr;
        break;
      }

      int bits_per_sample = preferred_bits_per_sample_;
      int sample_rate = preferred_sample_rate_;
      size_t number_of_channels = preferred_channels_;
      size_t number_of_frames = num_frames_to_read;

      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (callback_) {
          callback_(data, bits_per_sample, sample_rate,
                   number_of_channels, number_of_frames, user_data_);
        }
      }

      hr = capture_client_->ReleaseBuffer(num_frames_to_read);
      if (FAILED(hr)) {
        std::cout << "Failed to release buffer: " << hr;
        break;
      }

      hr = capture_client_->GetNextPacketSize(&num_frames_available);
      if (FAILED(hr)) {
        std::cout << "Failed to get next packet size: " << hr;
        break;
      }
    }

    Sleep(5);
  }

  std::cout << "Capture thread stopped" << std::endl;
}

std::vector<std::pair<std::string, std::string>> 
WinSysAudioCapturer::GetRecordingDevices() {
  std::vector<std::pair<std::string, std::string>> devices;
  
  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      __uuidof(IMMDeviceEnumerator),
      reinterpret_cast<void**>(&enumerator));
  
  if (FAILED(hr)) {
    std::cout << "Failed to create device enumerator";
    return devices;
  }

  IMMDeviceCollection* collection = nullptr;
  hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection);
  
  if (FAILED(hr)) {
    std::cout << "Failed to enumerate devices";
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
  
  std::cout << "Found " << devices.size() << " recording devices";
  return devices;
}

void WinSysAudioCapturer::CleanupCOM() {
  CoUninitialize();
}

bool WinSysAudioCapturer::IsSystemAudioCaptureSupported() {
  return true;
}

}  // namespace flutter_webrtc_plugin

//#endif  // _WIN32

