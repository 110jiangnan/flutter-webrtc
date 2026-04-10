package com.cloudwebrtc.sysAudio;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public class SystemAudioHelper {

    public static byte[] createData() {
        // 1. 定义常量参数
        final int sampleRate = 48000;
        final int channels = 2;
        final int bitsPerSample = 16;
        final int durationMs = 10; // 10毫秒

        // 2. 计算帧数和缓冲区大小
        int numberOfFrames = (sampleRate * durationMs) / 1000;
        int bufferSize = numberOfFrames * channels * (bitsPerSample / 8);

        // 3. 分配缓冲区并设置小端序
        ByteBuffer audioBuffer = ByteBuffer.allocate(bufferSize);
        audioBuffer.order(ByteOrder.LITTLE_ENDIAN);

        // 4. 生成正弦波数据
        double frequency = 440.0; // A4 音符

        for (int i = 0; i < numberOfFrames; ++i) {
            // 计算正弦波值
            double value = 0.23 * Math.sin(2.0 * Math.PI * frequency * i / sampleRate);

            // 转换为 short (int16_t)
            short sampleVal = (short) (value * Short.MAX_VALUE);

            // 写入左右声道 (立体声)
            audioBuffer.putShort(sampleVal); // 左
            audioBuffer.putShort(sampleVal); // 右
        }

        // 5. 返回底层字节数组
        return audioBuffer.array();
    }

}
