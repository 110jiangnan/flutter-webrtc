/* WebrtcRTCDesktopCapturer.h — mac 桌面采集 category 声明。
 * 让 WebrtcPlugin.mm 的 C ABI 入口层(WebrtcPlugin 主接口外)能干净地调用,
 * 免去 "no visible @interface declares the selector" 编译错误。
 */
#ifndef WEBRTC_RTC_DESKTOP_CAPTURER_H
#define WEBRTC_RTC_DESKTOP_CAPTURER_H

#import "WebrtcPlugin.h"

@interface WebrtcPlugin (RTCDesktopCapturer)

- (void)getDisplayMedia:(nonnull NSDictionary*)constraints
                 result:(nonnull WebrtcResult)result;

- (void)getDesktopSources:(nonnull NSDictionary*)argsMap
                   result:(nonnull WebrtcResult)result;

@end

#endif /* WEBRTC_RTC_DESKTOP_CAPTURER_H */
