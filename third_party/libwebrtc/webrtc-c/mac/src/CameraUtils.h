#import <Foundation/Foundation.h>
#import "WebrtcPlugin.h"

/* 照抄自 common/darwin/Classes/CameraUtils.h，但只保留 macOS 可用的摄像头格式
 * 辅助方法(findDeviceForPosition / selectFormatForDevice / selectFpsForFormat)。
 * darwin 里同文件的 torch/zoom/focus/exposure/switchCamera 等摄像头控制方法皆为
 * #if TARGET_OS_IPHONE，macOS 走 Not supported 分支，且依赖 iOS 独有 ivar
 * (self.videoCapturer/_lastTargetWidth 等，未迁入 mac 的 WebrtcPlugin)，webrtc-cli
 * 也不调用它们，故按覆盖范围裁剪。
 */
@interface WebrtcPlugin (CameraUtils)

- (nullable AVCaptureDevice*)findDeviceForPosition:(AVCaptureDevicePosition)position;

- (nullable AVCaptureDeviceFormat*)selectFormatForDevice:(nonnull AVCaptureDevice*)device
                                    targetWidth:(NSInteger)targetWidth
                                   targetHeight:(NSInteger)targetHeight;

- (NSInteger)selectFpsForFormat:(nonnull AVCaptureDeviceFormat*)format
                       targetFps:(NSInteger)targetFps;

@end
