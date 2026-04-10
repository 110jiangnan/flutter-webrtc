package com.cloudwebrtc.sysAudio;

import java.util.LinkedList;
import java.util.Queue;

public class AudioBufferCache {
    private final byte[] buffer;      // 核心缓存数组
    private int readPos = 0;          // 读指针（数据起始位置）
    private int writePos = 0;         // 写指针（数据结束位置）
    private final int targetFrameSize; // 目标 10ms 字节数
    public Queue<byte[]> queue = new LinkedList<>();

    /**
     * 初始化缓存
     */
    public AudioBufferCache(int sampleRate, int channels, int bitsPerSample) {
        // 计算 10ms 的字节大小
        int samplesPer10ms = sampleRate / 100;
        this.targetFrameSize = samplesPer10ms * channels * (bitsPerSample / 8);

        // 预分配缓冲区，假设最大能容纳 100ms 数据，防止频繁扩容
        // 实际大小根据你的需求调整，只要能装下 "最大单次输入 + targetFrameSize" 即可
        this.buffer = new byte[targetFrameSize * 10];
    }

    /**
     * 新增：获取帧数据的方法
     * 如果缓存中有足够的数据，则拷贝并返回一帧；否则返回 null。
     */
    public byte[] pollFrame() {
        int currentSize = writePos - readPos;

        // 检查是否攒够了 10ms
        if (currentSize >= targetFrameSize) {
            // 1. 尝试从队列复用数组，如果没有则新建
            byte[] frame = queue.poll();
            if (frame == null || frame.length != targetFrameSize) {
                frame = new byte[targetFrameSize];
            }

            // 2. 拷贝数据 (这是唯一的一次拷贝)
            System.arraycopy(buffer, readPos, frame, 0, targetFrameSize);

            // 3. 移动读指针
            readPos += targetFrameSize;

            // 4. 指针重置优化
            if (readPos == writePos) {
                readPos = 0;
                writePos = 0;
            }

            return frame;
        }

        return null;
    }
    /**
     * 追加数据并尝试提取 10ms 帧
     * @param data 输入数据
     * @return 10ms 数据块（如果够的话），否则 null
     */
    public void addData(byte[] data) {
        // 1. 确保缓冲区有足够空间容纳新数据
        // 如果 writePos + data.length 超过数组边界，需要搬移数据到头部
        ensureCapacity(data.length);
        // 2. 将新数据拷贝到缓冲区尾部 (这是第 1 次拷贝)
        System.arraycopy(data, 0, buffer, writePos, data.length);
        writePos += data.length;
    }

    /**
     * 确保缓冲区有足够空间。
     * 如果空间不足，将有效数据搬移到数组头部。
     */
    private void ensureCapacity(int incomingLength) {
        // 如果剩余空间不够了
        if (writePos + incomingLength > buffer.length) {
            int validSize = writePos - readPos;

            // 搬移有效数据到数组头部
            if (validSize > 0) {
                System.arraycopy(buffer, readPos, buffer, 0, validSize);
            }

            // 重置指针
            readPos = 0;
            writePos = validSize;
        }
    }

    // 调试用：获取当前缓存数据量
    public int getAvailableSize() {
        return writePos - readPos;
    }
}