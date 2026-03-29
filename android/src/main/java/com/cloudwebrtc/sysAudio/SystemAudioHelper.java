package com.cloudwebrtc.sysAudio;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;

import com.cloudwebrtc.webrtc.audio.LocalAudioTrack;

import org.webrtc.AudioTrack;
import org.webrtc.PeerConnectionFactory;


/**
 * 系统音频捕获助手类
 * 
 * 提供简单的 API 来请求权限并创建系统音频轨道
 */
@RequiresApi(api = Build.VERSION_CODES.Q)
public class SystemAudioHelper {


}
