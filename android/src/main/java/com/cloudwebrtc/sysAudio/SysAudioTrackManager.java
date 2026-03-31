package com.cloudwebrtc.sysAudio;

import static com.cloudwebrtc.webrtc.MethodCallHandlerImpl.resultError;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.AudioFormat;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.util.Log;
import androidx.annotation.RequiresApi;
import androidx.annotation.RequiresPermission;

import com.cloudwebrtc.webrtc.LocalTrack;
import com.cloudwebrtc.webrtc.MethodCallHandlerImpl;
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack;
import com.cloudwebrtc.webrtc.utils.ConstraintsArray;
import com.cloudwebrtc.webrtc.utils.ConstraintsMap;

import org.webrtc.AudioSource;
import org.webrtc.AudioTrack;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.audio.JavaAudioDeviceModule;

import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import io.flutter.plugin.common.MethodChannel.Result;

@RequiresApi(api = Build.VERSION_CODES.Q)
public class SysAudioTrackManager {
    private static final String TAG = "SysAudioTrackManager";
    private static SysAudioTrackManager instance;

    private final Context context;
    private final PeerConnectionFactory mFactory;
    MethodCallHandlerImpl methodCallHandler;
    
    // 核心组件
    private SystemAudioCapturer capturer;      // 音频捕获器
    private AudioSource audioSource;           // 音频源（只有 1 个）
    
    private final Map<String, LocalTrack> audioTracks = new ConcurrentHashMap<>();

    private boolean isInitialized = false;
    private Intent savedMediaProjectionIntent;  // 保存 Intent 以便创建更多轨道

    public String pcmPath;
    public boolean enablePcmRecord = false;
    FileOutputStream fos;
    AudioBufferCache audioBufferCache;

    public static SysAudioTrackManager GetInstance(Context context, PeerConnectionFactory factory, MethodCallHandlerImpl methodCallHandler) {
        if (instance == null) {
            instance = new SysAudioTrackManager(context, factory, methodCallHandler);
        }
        return instance;
    }

    public SysAudioTrackManager(Context context, PeerConnectionFactory factory, MethodCallHandlerImpl methodCallHandler) {
        this.context = context.getApplicationContext();
        this.mFactory = factory;
        this.methodCallHandler = methodCallHandler;
    }

    @SuppressLint("MissingPermission")
    public void GetSysAudioMedia(final ConstraintsMap constraints, final Result result) {
        if (isInitialized) {
            Log.e(TAG, "Not initialized. Call initialize() first.");
            resultError("GetSysAudioMedia", "isInitialized = true", result);
            return;
        }

        this.pcmPath = constraints.getString("pcmFilePath");
        this.enablePcmRecord = constraints.getBoolean("enablePcmRecording");
        if (enablePcmRecord && pcmPath != null) {
            try {
                fos = new FileOutputStream(pcmPath, true);
            } catch (FileNotFoundException e) {
                Log.e(TAG, "Failed to create file output stream", e);
            }
        }
        Intent projectionData = methodCallHandler.getUserMediaImpl.mediaProjectionData;
        if (projectionData == null) {
            Log.e(TAG, "MediaProjection permission not granted");
            resultError("GetSysAudioMedia", "MediaProjection permission not granted; projectionData is null", result);
            return;
        }
        MediaProjectionManager projectionManager =
                (MediaProjectionManager) context.getSystemService(Context.MEDIA_PROJECTION_SERVICE);

        MediaProjection mediaProjection = projectionManager.getMediaProjection(Activity.RESULT_OK, projectionData);
        if (mediaProjection == null) {
            Log.e(TAG, "MediaProjection is null");
            resultError("GetSysAudioMedia", "MediaProjection is null", result);
            return;
        }

        String streamId = methodCallHandler.getNextStreamUUID();
        MediaStream mediaStream = mFactory.createLocalMediaStream(streamId);

        if (mediaStream == null) {
            resultError("GetSysAudioMedia", "Failed to create new media stream", result);
            return;
        }
        ConstraintsMap trackParams = new ConstraintsMap();

        boolean initialize = initialize(projectionData, mediaProjection, mediaStream, trackParams);
        if (!initialize) {
            resultError("GetSysAudioMedia", "Failed to initialize system audio capture", result);
        } else {
            ConstraintsArray audioTracks = new ConstraintsArray();
            ConstraintsArray videoTracks = new ConstraintsArray();
            ConstraintsMap successResult = new ConstraintsMap();

            audioTracks.pushMap(trackParams);
            successResult.putString("streamId", streamId);
            successResult.putArray("audioTracks", audioTracks.toArrayList());
            successResult.putArray("videoTracks", videoTracks.toArrayList());

            result.success(successResult.toMap());
        }
    }
    
    /**
     * 初始化并启动系统音频捕获
     * 必须先调用此方法才能创建 AudioTrack
     * 
     * @param mediaProjectionIntent MediaProjection permission intent
     * @return true 如果成功启动
     */
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    public boolean initialize(Intent mediaProjectionIntent, MediaProjection projection,
                              MediaStream stream, ConstraintsMap trackParams) {
        if (!SystemAudioCapturer.isSupported()) {
            Log.e(TAG, "System audio capture not supported on this Android version");
            return false;
        }
        if (isInitialized) {
            Log.w(TAG, "Already initialized");
            return false;
        }
        try {
            // 保存 Intent 以便后续创建更多轨道
            this.savedMediaProjectionIntent = mediaProjectionIntent;
            // 创建 AudioSource（只有 1 个）
            MediaConstraints constraints = new MediaConstraints();
            audioSource = mFactory.createAudioSource(constraints);

            String trackId = methodCallHandler.getNextTrackUUID();
            AudioTrack track = mFactory.createAudioTrack(trackId, audioSource);
            stream.addTrack(track);
            LocalAudioTrack localAudioTrack = new LocalAudioTrack(track);
            localAudioTrack.sType = "sysAudio";
            // 保存到 Map 中
            audioTracks.put(trackId, localAudioTrack);

            trackParams.putBoolean("enabled", track.enabled());
            trackParams.putString("id", track.id());
            trackParams.putString("kind", "audio");
            trackParams.putString("label", track.id());
            trackParams.putString("readyState", track.state().toString());
            trackParams.putBoolean("remote", false);

            ConstraintsMap settings = new ConstraintsMap();
            settings.putString("deviceId", "");
            settings.putString("kind", "audioinput");
            settings.putBoolean("autoGainControl", false);
            settings.putBoolean("echoCancellation", false);
            settings.putBoolean("noiseSuppression", false);
            settings.putInt("channelCount", 2);
            settings.putInt("latency", 0);
            trackParams.putMap("settings", settings.toMap());

            // 创建捕获器
            capturer = new SystemAudioCapturer(context);
            
            // 设置回调 - 当有音频数据时推送给所有 AudioTrack
            capturer.setCallback(new SystemAudioCapturer.CaptureCallback() {
                @Override
                public void onCaptureStarted() {
                    Log.i(TAG, "System audio capture started");
                    isInitialized = true;
                }
                
                @Override
                public void onCaptureStopped() {
                    Log.i(TAG, "System audio capture stopped");
                    isInitialized = false;
                }
                
                @Override
                public void onError(String error) {
                    Log.e(TAG, "Capture error: " + error);
                    isInitialized = false;
                }
                
                @Override
                public void onPCMDataAvailable(byte[] pcmData, int sampleRate, int channels, int bitsPerSample) {
                    // 将 PCM 数据推送给所有注册的 AudioTrack
                    pushDataToAllTracks(pcmData, sampleRate, channels, bitsPerSample);
                }
            });
            
            // 启动捕获
            if (!capturer.startCapture(mediaProjectionIntent, projection)) {
                Log.e(TAG, "Failed to start system audio capture");
                methodCallHandler.streamDispose(stream.getId());
                cleanup();
                return false;
            }
            audioBufferCache = new AudioBufferCache(SystemAudioCapturer.SAMPLE_RATE,
                    SystemAudioCapturer.CHANNEL_COUNT, SystemAudioCapturer.BITS_PER_SAMPLE);
            methodCallHandler.putLocalStream(stream.getId(), stream);
            methodCallHandler.putLocalTrack(localAudioTrack.id(), localAudioTrack);
            
            Log.i(TAG, "System audio capture initialized successfully");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize: " + e.getMessage(), e);
            methodCallHandler.streamDispose(stream.getId());
            cleanup();
            return false;
        }
    }


    public void ReleaseSysAudioMedia(final ConstraintsMap constraints, final Result result) {
        dispose();
        instance = null;
        result.success(null);
    }
    /**
     * 开始捕获（如果已经初始化但停止了）
     */
    public boolean startCapture() {
        if (capturer != null && !capturer.isCapturing()) {
            // 需要重新传递 Intent，或者在创建时已经保存
            Log.w(TAG, "Cannot restart capture without MediaProjection intent");
            return false;
        }
        return capturer != null && capturer.isCapturing();
    }
    
    /**
     * 停止捕获
     */
    public void stopCapture() {
        if (capturer != null) {
            capturer.stopCapture();
        }
    }
    
    /**
     * 将 PCM 数据推送给所有已注册的 AudioTrack
     * 参考 flutter-webrtc MethodCallHandlerImpl.java L252-L256
     */
    private void pushDataToAllTracks(byte[] pcmData, int sampleRate, int channels, int bitsPerSample) {
        if (audioTracks.isEmpty()) {
            return;
        }
        byte[] testData = SystemAudioHelper.createData();
        JavaAudioDeviceModule.AudioSamples audioSamples = new JavaAudioDeviceModule.AudioSamples(SystemAudioCapturer.AUDIO_FORMAT, channels,
                        sampleRate, testData);
        for (LocalTrack track : audioTracks.values()) {
            if (track != null) {
//                Log.i("zjn", "pushDataToAllTracks：" + pcmData.length);
                if (track instanceof LocalAudioTrack) {
                    ((LocalAudioTrack) track).onWebRtcAudioRecordSamplesReady(audioSamples);
                }
            }
        }

        /*audioBufferCache.addData(pcmData);
        byte[] frame;
        while ((frame = audioBufferCache.pollFrame()) != null) {
            // 构造 AudioSamples 对象
            JavaAudioDeviceModule.AudioSamples audioSamples =
                    new JavaAudioDeviceModule.AudioSamples(SystemAudioCapturer.AUDIO_FORMAT, channels,
                            sampleRate, frame);

            // 遍历所有 AudioTrack 并推送数据
            for (LocalTrack track : audioTracks.values()) {
                if (track != null) {
                    // 调用 LocalAudioTrack 的回调方法
                    if (track instanceof LocalAudioTrack) {
                        ((LocalAudioTrack) track).onWebRtcAudioRecordSamplesReady(audioSamples);
                    }
                }
            }
            audioBufferCache.queue.offer(frame);
        }*/

        if (enablePcmRecord && pcmPath != null && fos != null) {
            try {
                fos.write(pcmData);
            } catch (IOException e) {
                Log.e(TAG, "Failed to write PCM data to file: " + e.getMessage(), e);
            }
        }
    }

    /**
     * 移除并释放指定的 AudioTrack
     * 
     * @param trackId 轨道 ID
     */
    public void removeSystemAudioTrack(String trackId) {
        LocalTrack track = audioTracks.remove(trackId);
        Log.i(TAG, "Removed system audio track: " + trackId);
    }
    
    /**
     * 获取所有已创建的 AudioTrack
     */
    public ArrayList<LocalTrack> getAllAudioTracks() {
        return new ArrayList<>(audioTracks.values());
    }
    
    /**
     * 获取指定 ID 的 AudioTrack
     */
    public LocalTrack getAudioTrack(String trackId) {
        return audioTracks.get(trackId);
    }
    
    /**
     * 检查是否正在捕获
     */
    public boolean isCapturing() {
        return capturer != null && capturer.isCapturing();
    }
    
    /**
     * 释放资源
     */
    public void dispose() {
        Log.i(TAG, "Disposing system audio track manager");
        stopCapture();
        cleanup();
    }
    
    private void cleanup() {
        if (capturer != null) {
            capturer.release();
            capturer = null;
        }
        
        // AudioTrack 释放由外部做
        audioTracks.clear();

        if (audioSource != null) {
            audioSource.dispose();
            audioSource = null;
        }
        if (fos != null) {
            try {
                fos.close();
                fos = null;
            } catch (IOException e) {
                Log.e(TAG, "Failed to close file: " + e.getMessage(), e);
            }
        }

        savedMediaProjectionIntent = null;
        isInitialized = false;
    }
}
