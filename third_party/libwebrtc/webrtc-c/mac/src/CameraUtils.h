#import <Foundation/Foundation.h>
#import "WebrtcPlugin.h"

/* 照抄自 common/darwin/Classes/CameraUtils.h，但只保留 macOS 可用的摄像头格式
 * 辅助方法(findDeviceForPosition / selectFormatForDevice / selectFpsForFormat)。
 * darwin 里同文件的 torch/zoom/focus/exposure/switchCamera 等摄像头控制方法皆为
 * #if TARGET_OS_IPHONE，macOS 走 Not supported 分支，且依赖 iOS 独有 ivar
 * (self.videoCapturer/_lastTargetWidth 等，未迁入 mac 的 WebrtcPlugin)，webrtc-cli
 * 也不调用它们，故按覆盖范围裁剪。
 */
@class RTCCameraVideoCapturer;

@interface WebrtcPlugin (CameraUtils)

/* 供 selectFormatForDevice 决胜用: 同分辨率时优先 preferredOutputPixelFormat。
 * 实现是 WebrtcRTCMediaStream.mm 的 associated object(videoCapturer 未进 WebrtcPlugin.h),
 * 这里仅声明让 CameraUtils 能调用, 访问器方法在运行时解析到该实现。 */
@property(nonatomic, strong, nullable) RTCCameraVideoCapturer* videoCapturer;

- (nullable AVCaptureDevice*)findDeviceForPosition:(AVCaptureDevicePosition)position;

- (nullable AVCaptureDeviceFormat*)selectFormatForDevice:(nonnull AVCaptureDevice*)device
                                    targetWidth:(NSInteger)targetWidth
                                   targetHeight:(NSInteger)targetHeight;

- (NSInteger)selectFpsForFormat:(nonnull AVCaptureDeviceFormat*)format
                       targetFps:(NSInteger)targetFps;

@end
