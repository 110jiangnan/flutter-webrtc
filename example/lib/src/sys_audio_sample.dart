import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/src/sys_audio_manager.dart';
import 'package:path_provider/path_provider.dart';

/// 系统音频捕获示例
/// System Audio Capture Sample
class SysAudioSample extends StatefulWidget {
  @override
  SysAudioSampleState createState() => SysAudioSampleState();
}

class SysAudioSampleState extends State<SysAudioSample> {
  MediaStream? _sysAudioStream;
  RTCPeerConnection? _peerConnection;
  bool _isCapturing = false;
  String _selectedDeviceId = '';
  final List<Map<String, dynamic>> _audioDevices = [];
  bool _isPcmRecording = false;
  String? _pcmFilePath;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // 获取音频设备列表
    await _getAudioDevices();
  }

  Future<void> _getAudioDevices() async {
    try {
      // TODO: 需要添加 getSysAudioDevices 方法到 Flutter 插件
      // final devices = await SysAudioManager.getSysAudioDevices();
      // setState(() {
      //   _audioDevices = devices;
      // });
      print('音频设备列表获取成功');
    } catch (e) {
      print('获取音频设备失败：$e');
    }
  }

  Future<void> _startSysAudioCapture() async {
    try {
      final tempDir = await getTemporaryDirectory();
      var pcmFilePath = 'E:/pcm.pcm';
      if (Platform.isAndroid) {
        pcmFilePath = '${tempDir.path}/pcm11.pcm';
      } else if (Platform.isLinux) {
        pcmFilePath = '${tempDir.path}/pcm.pcm';
      } else if (Platform.isMacOS) {
        pcmFilePath = '${tempDir.path}/pcm.pcm';
      }
      print('pcm 文件路径：$pcmFilePath');
      if (WebRTC.platformIsAndroid) {
        await requestBackgroundPermission();
      }
      final result = await SysAudioManager.getSysAudioMedia(
        deviceId: _selectedDeviceId,
        streamId: '',
        enablePcmRecording: true,
        pcmFilePath: pcmFilePath,
      );

      setState(() {
        _sysAudioStream = result;
        _isCapturing = true;
      });

      print('系统音频捕获启动成功');
    } catch (e) {
      print('启动系统音频捕获失败：$e');
    }
  }

  Future<void> _stopSysAudioCapture() async {
    try {
      if (_sysAudioStream != null) {
        // 停止所有轨道
        for (var track in _sysAudioStream!.getAudioTracks()) {
          await track.stop();
        }

        // 调用 ReleaseSysAudioMedia _sysAudioStream 已经被释放掉了，无需再dispose
        await SysAudioManager.releaseSysAudioMedia(_sysAudioStream!.id);
        _sysAudioStream = null;

        setState(() {
          _isCapturing = false;
        });

        print('系统音频捕获已停止');
      }
    } catch (e) {
      print('停止系统音频捕获失败：$e');
    }
  }

  static Future<bool> requestBackgroundPermission([bool isRetry = false]) async {
    try {
      final isGranted = await Helper.requestCapturePermission();
      if (!isGranted) {
        throw '请授予系统音频捕获权限';
      }
      var hasPermissions = await FlutterBackground.hasPermissions;
      if (!isRetry) {
        const androidConfig = FlutterBackgroundAndroidConfig(
          notificationTitle: 'Screen Sharing',
          notificationText: 'LiveKit Example is sharing the screen.',
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon: AndroidResource(
              name: 'livekit_ic_launcher', defType: 'mipmap'),
        );
        hasPermissions = await FlutterBackground.initialize(
            androidConfig: androidConfig);
      }
      if (hasPermissions &&
          !FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.enableBackgroundExecution();
      }
      return true;
    } catch (e) {
      if (!isRetry) {
        return await Future<bool>.delayed(const Duration(seconds: 1),
                () => requestBackgroundPermission(true));
      }
      print('could not publish video: $e');
      return false;
    }
  }

  Future<void> _createPeerConnection() async {
    try {
      _peerConnection = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'}
        ]
      });
      setState(() {
      });
      print('PeerConnection 创建成功');
    } catch (e) {
      print('创建 PeerConnection 失败：$e');
    }
  }

  Future<void> _addSysAudioToPeerConnection() async {
    try {
      if (_sysAudioStream != null && _peerConnection != null) {
        // 将系统音频添加到通话中
        for (var track in _sysAudioStream!.getAudioTracks()) {
          await _peerConnection!.addTrack(track, _sysAudioStream!);
        }
        print('系统音频已添加到 PeerConnection');
      }
    } catch (e) {
      print('添加系统音频到通话失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('系统音频捕获示例'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '系统音频捕获 (System Audio Capture)',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            SizedBox(height: 20),
            
            // 设备选择
            if (_audioDevices.isNotEmpty) ...[
              Text('选择音频设备:'),
              DropdownButton<String>(
                value: _selectedDeviceId.isEmpty ? null : _selectedDeviceId,
                hint: Text('默认设备'),
                onChanged: (String? newValue) {
                  setState(() {
                    _selectedDeviceId = newValue ?? '';
                  });
                },
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Text('默认设备'),
                  ),
                  ..._audioDevices.map((device) {
                    return DropdownMenuItem<String>(
                      value: device['id'],
                      child: Text(device['name']),
                    );
                  }).toList(),
                ],
              ),
              SizedBox(height: 20),
            ],

            // 控制按钮
            Wrap(
              children: [
                ElevatedButton(
                  onPressed: _isCapturing ? null : _startSysAudioCapture,
                  child: Text('开始捕获'),
                ),
                SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _isCapturing ? _stopSysAudioCapture : null,
                  child: Text('停止捕获'),
                ),
                SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _peerConnection == null 
                      ? _createPeerConnection 
                      : null,
                  child: Text('创建 PeerConnection'),
                ),
                SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _peerConnection != null && _sysAudioStream != null
                      ? _addSysAudioToPeerConnection
                      : null,
                  child: Text('添加到通话'),
                ),
              ],
            ),
            SizedBox(height: 10),
            
            // PCM 录制测试按钮
            Row(
              children: [
                ElevatedButton(
                  onPressed: _togglePcmRecording,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isPcmRecording ? Colors.red : null,
                  ),
                  child: Text(_isPcmRecording ? '停止 PCM 录制' : '开始 PCM 录制'),
                ),
                SizedBox(width: 10),
                if (_isPcmRecording && _pcmFilePath != null)
                  Expanded(
                    child: Text(
                      '录制文件：$_pcmFilePath',
                      style: TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),

            SizedBox(height: 20),

            // 状态显示
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '状态:',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(height: 10),
                    Text('捕获状态：${_isCapturing ? '正在捕获' : '未捕获'}'),
                    Text('流 ID: ${_sysAudioStream?.id ?? "无"}'),
                    Text('音频轨道数：${_sysAudioStream?.getAudioTracks().length ?? 0}'),
                    Text('PeerConnection: ${_peerConnection != null ? '已创建' : "未创建"}'),
                  ],
                ),
              ),
            ),

            SizedBox(height: 20),

            // 使用说明
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '使用说明:',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(height: 10),
                    Text('1. 选择一个音频设备（可选，不选则使用默认设备）'),
                    Text('2. 点击"开始捕获"启动系统音频捕获'),
                    Text('3. 点击"创建 PeerConnection"创建 WebRTC 连接'),
                    Text('4. 点击"添加到通话"将系统音频添加到通话中'),
                    Text('5. 可以创建多个 MediaStream 共享同一个系统音频源'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopSysAudioCapture();
    _peerConnection?.close();
    super.dispose();
  }

  // 测试功能：PCM 文件录制（单独控制）
  Future<void> _togglePcmRecording() async {
    try {
      if (!_isPcmRecording) {
        // 开启 PCM 录制
        final result = await SysAudioManager.enableSysAudioPcmRecording(
          enable: true,
          filePath: '', // 空路径会自动生成 E:/sys_audio_时间戳.pcm
        );
        
        setState(() {
          _isPcmRecording = true;
          _pcmFilePath = result['filePath'];
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PCM 录制已开始：${_pcmFilePath}'),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        // 停止 PCM 录制
        await SysAudioManager.enableSysAudioPcmRecording(
          enable: false,
          filePath: '',
        );
        
        setState(() {
          _isPcmRecording = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PCM 录制已停止，文件保存在：$_pcmFilePath'),
            duration: const Duration(seconds: 5),
          ),
        );
        
        _pcmFilePath = null;
      }
    } catch (e) {
      print('PCM 录制失败：$e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PCM 录制失败：$e')),
      );
    }
  }
}
