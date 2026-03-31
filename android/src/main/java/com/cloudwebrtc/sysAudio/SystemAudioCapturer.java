package com.cloudwebrtc.sysAudio;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.os.Build;
import android.util.Log;
import androidx.annotation.RequiresApi;
import androidx.annotation.RequiresPermission;
import java.nio.ByteBuffer;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

@RequiresApi(api = Build.VERSION_CODES.Q)
public class SystemAudioCapturer {
    private static final String TAG = "SystemAudioCapturer";
    
    // 音频参数
    public static final int SAMPLE_RATE = 48000;  // 48kHz
    public static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_STEREO;  // 立体声
    public static final int AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT;   // 16-bit
    public static final int CHANNEL_COUNT = 2;
    public static final int BITS_PER_SAMPLE = 16;  // 16-bit
    public static final int BYTES_PER_FRAME = CHANNEL_COUNT * (BITS_PER_SAMPLE / 8);  // 16-bit = 2 bytes
    
    // 缓冲区大小（10ms 音频数据）
    private static final int BUFFER_SIZE_IN_FRAMES = SAMPLE_RATE / 100;  // 480 frames @ 48kHz
    private static final int BUFFER_SIZE_IN_BYTES = BUFFER_SIZE_IN_FRAMES * BYTES_PER_FRAME;
    
    private final Context context;

    // 使用 AudioRecord 直接录制系统音频
    private AudioRecord audioRecord;
    private volatile boolean isCapturing = false;
    private volatile boolean shouldStop = false;
    
    // 使用 ScheduledExecutorService 进行精确的 10ms 定时
    private ScheduledExecutorService captureScheduler;
    private ScheduledFuture<?> captureFuture;
    
    // 回调接口
    public interface CaptureCallback {
        void onCaptureStarted();
        void onCaptureStopped();
        void onError(String error);
        // PCM 数据回调（每 10ms 调用一次）
        void onPCMDataAvailable(byte[] pcmData, int sampleRate, int channels, int bitsPerSample);
    }
    
    private CaptureCallback callback;
    private final ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(1);
    
    public SystemAudioCapturer(Context context) {
        this.context = context.getApplicationContext();
    }
    
    /**
     * 初始化并启动系统音频捕获
     * @param mediaProjectionIntent MediaProjection permission intent
     * @return true 如果成功启动
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    public boolean startCapture(Intent mediaProjectionIntent, MediaProjection projection) {
        if (isCapturing) {
            Log.w(TAG, "Already capturing");
            return false;
        }
        
        try {
            AudioPlaybackCaptureConfiguration config =
                new AudioPlaybackCaptureConfiguration.Builder(projection)
                        .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                        .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                        .addMatchingUsage(AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(AudioAttributes.USAGE_ALARM)
                        .addMatchingUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .build();
            
            // 计算最小缓冲区大小
            int minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT);
            if (minBufferSize == AudioRecord.ERROR || minBufferSize == AudioRecord.ERROR_BAD_VALUE) {
                Log.e(TAG, "Invalid buffer size: " + minBufferSize);
                return false;
            }
            
            // 使用较大的缓冲区以确保稳定性
            int bufferSize = Math.max(minBufferSize, BUFFER_SIZE_IN_BYTES * 4);
            
            // 创建 AudioRecord - 这是实际录制的地方
            audioRecord = new AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(config)  // ← 关键：使用系统音频捕获
                .setAudioFormat(new AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(CHANNEL_CONFIG)
                    .setEncoding(AUDIO_FORMAT)
                    .build())
                .setBufferSizeInBytes(bufferSize)
                .build();
            
            if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "AudioRecord initialization failed");
                return false;
            }

            Log.i(TAG, "AudioRecord initialized successfully");
            Log.i(TAG, "Sample rate: " + SAMPLE_RATE + " Hz");
            Log.i(TAG, "Channels: Stereo");
            Log.i(TAG, "Format: PCM " + GetBytesPerSample(AUDIO_FORMAT) + "-bit");
            Log.i(TAG, "Buffer size: " + bufferSize + " bytes");
            
            // 启动录音
            audioRecord.startRecording();
            Log.i(TAG, "AudioRecord started");
            
            isCapturing = true;
            shouldStop = false;
            
            // 使用定时器每 10ms 读取一次音频数据
            captureScheduler = Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "SystemAudioCaptureTimer");
                t.setPriority(Thread.MAX_PRIORITY);
                return t;
            });
            
            captureFuture = captureScheduler.scheduleWithFixedDelay(
                this::readAudioData,
                0,
                10,
                TimeUnit.MILLISECONDS
            );
            
            Log.i(TAG, "Started periodic audio capture with 10ms interval");
            
            if (callback != null) {
                callback.onCaptureStarted();
            }
            
            return true;
        } catch (SecurityException e) {
            Log.e(TAG, "Permission denied: " + e.getMessage());
            if (callback != null) {
                callback.onError("Permission denied: " + e.getMessage());
            }
            return false;
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize AudioRecord: " + e.getMessage(), e);
            if (callback != null) {
                callback.onError("Initialization failed: " + e.getMessage());
            }
            return false;
        }
    }
    
    /**
     * 定时读取音频数据（每 10ms 调用一次）并传递给
     */
    private void readAudioData() {
        if (shouldStop) {
            return;
        }
        
        try {
            ByteBuffer audioBuffer = ByteBuffer.allocateDirect(BUFFER_SIZE_IN_BYTES);
            int bytesRead = audioRecord.read(audioBuffer, audioBuffer.capacity());
            
            if (bytesRead > 0) {
                audioBuffer.rewind();
                // 通过回调传递 PCM 数据给外层
                byte[] pcmData = new byte[bytesRead];
                audioBuffer.get(pcmData);
                if (callback != null) {
                    callback.onPCMDataAvailable(
                        pcmData,
                        SAMPLE_RATE,
                        CHANNEL_COUNT,
                        BITS_PER_SAMPLE
                    );
                }
//                Log.d(TAG, "Captured and delivered " + bytesRead + " bytes");
            } else if (bytesRead < 0) {
                Log.e(TAG, "Error reading from AudioRecord: " + bytesRead);
                stopCapture();
                if (callback != null) {
                    callback.onError("AudioRecord read error: " + bytesRead);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Error in audio data read: " + e.getMessage(), e);
            if (callback != null) {
                callback.onError("Read error: " + e.getMessage());
            }
        }
    }
    
    /**
     * 停止音频捕获
     */
    public void stopCapture() {
        if (!isCapturing) {
            return;
        }
        
        shouldStop = true;
        isCapturing = false;
        
        // 停止定时器
        if (captureFuture != null) {
            captureFuture.cancel(false);
            captureFuture = null;
        }
        
        if (captureScheduler != null) {
            captureScheduler.shutdown();
            try {
                if (!captureScheduler.awaitTermination(1, TimeUnit.SECONDS)) {
                    captureScheduler.shutdownNow();
                }
            } catch (InterruptedException e) {
                captureScheduler.shutdownNow();
                Thread.currentThread().interrupt();
            }
            captureScheduler = null;
        }
        
        // 停止 AudioRecord
        if (audioRecord != null && audioRecord.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) {
            audioRecord.stop();
            Log.i(TAG, "AudioRecord stopped");
        }
        
        Log.i(TAG, "Capture stopped");
        
        if (callback != null) {
            callback.onCaptureStopped();
        }
    }
    
    /**
     * 释放资源
     */
    public void release() {
        stopCapture();
        if (audioRecord != null) {
            audioRecord.release();
            audioRecord = null;
        }
        scheduler.shutdown();
        Log.i(TAG, "Resources released");
    }
    
    /**
     * 检查是否正在捕获
     */
    public boolean isCapturing() {
        return isCapturing;
    }
    
    /**
     * 设置回调
     */
    public void setCallback(CaptureCallback callback) {
        this.callback = callback;
    }
    
    /**
     * 检查系统音频捕获是否可用
     */
    public static boolean isSupported() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
    }

    public static int GetBytesPerSample(int audioFormat) {
        switch (audioFormat) {
            case AudioFormat.ENCODING_PCM_8BIT:
                return 1;
            case AudioFormat.ENCODING_PCM_16BIT:
            case AudioFormat.ENCODING_IEC61937:
            case AudioFormat.ENCODING_DEFAULT:
                return 2;
            case AudioFormat.ENCODING_PCM_FLOAT:
                return 4;
            default:
                throw new IllegalArgumentException("Bad audio format " + audioFormat);
        }
    }
}
