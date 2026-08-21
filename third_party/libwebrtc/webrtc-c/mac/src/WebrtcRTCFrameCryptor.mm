/* WebrtcRTCFrameCryptor.mm — mac 独立 C ABI 的 FrameCryptor/KeyProvider 业务方法。
 *
 * 照抄自 common/darwin/Classes/FlutterRTCFrameCryptor.m，去 Flutter：
 *   - FlutterResult → WebrtcResult; FlutterError → WebrtcError;
 *   - FlutterStandardTypedData(字节数组) ↔ JSON 数字数组(WebrtcDataFromJsonArr /
 *     WebrtcJsonArrFromData), 与 win/linux C ABI 的 JSON 边界一致;
 *   - eventChannel/eventSink 删除: 状态事件由 plugin 作 RTCFrameCryptorDelegate
 *     经 postFactoryEvent 上报(factory.dart 的 frameCryptionStateChanged 路由);
 *   - frameCryptorFactoryCreateFrameCryptor 不再按 peerConnectionId 查表,
 *     直接收 RTCPeerConnection* 指针(本 C ABI 以句柄传递 pc)。
 * 业务方法声明在 WebrtcPlugin.h(框架保持单一声明点), 本文件只做实现。
 */
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

#import "WebrtcPlugin.h"

#pragma mark - JSON 数字数组 <-> NSData 互转

// constraints 里的 key/ratchetSalt/sifTrailer 等字节数组在 C 边界是 JSON 数字数组(win/linux 同)
static NSData* WebrtcDataFromJsonArr(id obj) {
  if (![obj isKindOfClass:[NSArray class]]) return nil;
  NSMutableData* out = [NSMutableData dataWithCapacity:[obj count]];
  for (id item in obj) {
    uint8_t b = (uint8_t)[(NSNumber*)item intValue];
    [out appendBytes:&b length:1];
  }
  return out;
}

// 结果里的 NSData 要还原成 JSON 数字数组(不能走 WebrtcJsonSanitize 的 base64)
static NSArray* WebrtcJsonArrFromData(NSData* data) {
  NSMutableArray* out = [NSMutableArray arrayWithCapacity:data.length];
  const uint8_t* bytes = data.bytes;
  for (NSUInteger i = 0; i < data.length; i++) {
    [out addObject:@(bytes[i])];
  }
  return out;
}

#pragma mark - WebrtcPlugin (FrameCryptor) 实现

@implementation WebrtcPlugin (FrameCryptor)

- (RTCCryptorAlgorithm)getAlgorithm:(NSNumber*)algorithm {
  switch ([algorithm intValue]) {
    case 0:
      return RTCCryptorAlgorithmAesGcm;
    default:
      return RTCCryptorAlgorithmAesGcm;
  }
}

- (NSString*)stringFromFrameCryptorState:(RTCFrameCryptorState)state {
  switch (state) {
    case RTCFrameCryptorStateNew:
      return @"new";
    case RTCFrameCryptorStateOk:
      return @"ok";
    case RTCFrameCryptorStateEncryptionFailed:
      return @"encryptionFailed";
    case RTCFrameCryptorStateDecryptionFailed:
      return @"decryptionFailed";
    case RTCFrameCryptorStateMissingKey:
      return @"missingKey";
    case RTCFrameCryptorStateKeyRatcheted:
      return @"keyRatcheted";
    case RTCFrameCryptorStateInternalError:
      return @"internalError";
    default:
      return @"unknown";
  }
}

- (void)frameCryptorFactoryCreateFrameCryptor:(NSDictionary*)constraints
                               peerConnection:(RTCPeerConnection*)peerConnection
                                       result:(WebrtcResult)result {
  if (peerConnection == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateFrameCryptorFailed"
                              message:@"Error: peerConnection not found!"
                              details:nil]);
    return;
  }

  NSNumber* algorithm = constraints[@"algorithm"];
  if (algorithm == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateFrameCryptorFailed"
                              message:@"Invalid algorithm"
                              details:nil]);
    return;
  }

  NSString* participantId = constraints[@"participantId"];
  if (participantId == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateFrameCryptorFailed"
                              message:@"Invalid participantId"
                              details:nil]);
    return;
  }

  NSString* keyProviderId = constraints[@"keyProviderId"];
  if (keyProviderId == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateFrameCryptorFailed"
                              message:@"Invalid keyProviderId"
                              details:nil]);
    return;
  }

  RTCFrameCryptorKeyProvider* keyProvider = self.keyProviders[keyProviderId];
  if (keyProvider == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateFrameCryptorFailed"
                              message:@"Invalid keyProvider"
                              details:nil]);
    return;
  }

  NSString* type = constraints[@"type"];
  NSString* rtpSenderId = constraints[@"rtpSenderId"];
  NSString* rtpReceiverId = constraints[@"rtpReceiverId"];

  if ([type isEqualToString:@"sender"]) {
    RTCRtpSender* sender = [self getRtpSenderById:peerConnection Id:rtpSenderId];
    if (sender == nil) {
      result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateFrameCryptorFailed"
                                message:@"Error: sender not found!"
                                details:nil]);
      return;
    }

    RTCFrameCryptor* frameCryptor =
        [[RTCFrameCryptor alloc] initWithFactory:self.peerConnectionFactory
                                         rtpSender:sender
                                     participantId:participantId
                                         algorithm:[self getAlgorithm:algorithm]
                                        keyProvider:keyProvider];
    NSString* frameCryptorId = [[NSUUID UUID] UUIDString];

    frameCryptor.delegate = self;

    self.frameCryptors[frameCryptorId] = frameCryptor;
    result(@{@"frameCryptorId" : frameCryptorId});
  } else if ([type isEqualToString:@"receiver"]) {
    RTCRtpReceiver* receiver = [self getRtpReceiverById:peerConnection Id:rtpReceiverId];
    if (receiver == nil) {
      result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateFrameCryptorFailed"
                                message:@"Error: receiver not found!"
                                details:nil]);
      return;
    }
    RTCFrameCryptor* frameCryptor =
        [[RTCFrameCryptor alloc] initWithFactory:self.peerConnectionFactory
                                         rtpReceiver:receiver
                                       participantId:participantId
                                           algorithm:[self getAlgorithm:algorithm]
                                          keyProvider:keyProvider];
    NSString* frameCryptorId = [[NSUUID UUID] UUIDString];

    frameCryptor.delegate = self;

    self.frameCryptors[frameCryptorId] = frameCryptor;
    result(@{@"frameCryptorId" : frameCryptorId});
  } else {
    result([WebrtcError errorWithCode:@"InvalidArgument" message:@"Invalid type" details:nil]);
    return;
  }
}

- (void)frameCryptorSetKeyIndex:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* frameCryptorId = constraints[@"frameCryptorId"];
  if (frameCryptorId == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorSetKeyIndexFailed"
                              message:@"Invalid frameCryptorId"
                              details:nil]);
    return;
  }
  RTCFrameCryptor* frameCryptor = self.frameCryptors[frameCryptorId];
  if (frameCryptor == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorSetKeyIndexFailed"
                              message:@"Invalid frameCryptor"
                              details:nil]);
    return;
  }

  NSNumber* keyIndex = constraints[@"keyIndex"];
  if (keyIndex == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorSetKeyIndexFailed"
                              message:@"Invalid keyIndex"
                              details:nil]);
    return;
  }
  [frameCryptor setKeyIndex:[keyIndex intValue]];
  result(@{@"result" : @YES});
}

- (void)frameCryptorGetKeyIndex:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* frameCryptorId = constraints[@"frameCryptorId"];
  if (frameCryptorId == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorGetKeyIndexFailed"
                              message:@"Invalid frameCryptorId"
                              details:nil]);
    return;
  }
  RTCFrameCryptor* frameCryptor = self.frameCryptors[frameCryptorId];
  if (frameCryptor == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorGetKeyIndexFailed"
                              message:@"Invalid frameCryptor"
                              details:nil]);
    return;
  }
  result(@{@"keyIndex" : [NSNumber numberWithInt:frameCryptor.keyIndex]});
}

- (void)frameCryptorSetEnabled:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* frameCryptorId = constraints[@"frameCryptorId"];
  if (frameCryptorId == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorSetEnabledFailed"
                              message:@"Invalid frameCryptorId"
                              details:nil]);
    return;
  }
  RTCFrameCryptor* frameCryptor = self.frameCryptors[frameCryptorId];
  if (frameCryptor == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorSetEnabledFailed"
                              message:@"Invalid frameCryptor"
                              details:nil]);
    return;
  }

  NSNumber* enabled = constraints[@"enabled"];
  if (enabled == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorSetEnabledFailed"
                              message:@"Invalid enabled"
                              details:nil]);
    return;
  }
  frameCryptor.enabled = [enabled boolValue];
  result(@{@"result" : enabled});
}

- (void)frameCryptorGetEnabled:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* frameCryptorId = constraints[@"frameCryptorId"];
  if (frameCryptorId == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorGetEnabledFailed"
                              message:@"Invalid frameCryptorId"
                              details:nil]);
    return;
  }
  RTCFrameCryptor* frameCryptor = self.frameCryptors[frameCryptorId];
  if (frameCryptor == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorGetEnabledFailed"
                              message:@"Invalid frameCryptor"
                              details:nil]);
    return;
  }
  result(@{@"enabled" : [NSNumber numberWithBool:frameCryptor.enabled]});
}

- (void)frameCryptorDispose:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* frameCryptorId = constraints[@"frameCryptorId"];
  if (frameCryptorId == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorDisposeFailed"
                              message:@"Invalid frameCryptorId"
                              details:nil]);
    return;
  }
  RTCFrameCryptor* frameCryptor = self.frameCryptors[frameCryptorId];
  if (frameCryptor == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorDisposeFailed"
                              message:@"Invalid frameCryptor"
                              details:nil]);
    return;
  }
  [self.frameCryptors removeObjectForKey:frameCryptorId];
  frameCryptor.enabled = NO;
  result(@{@"result" : @"success"});
}

- (void)frameCryptorFactoryCreateKeyProvider:(NSDictionary*)constraints
                                      result:(WebrtcResult)result {
  NSString* keyProviderId = [[NSUUID UUID] UUIDString];

  id keyProviderOptions = constraints[@"keyProviderOptions"];
  if (keyProviderOptions == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateKeyProviderFailed"
                              message:@"Invalid keyProviderOptions"
                              details:nil]);
    return;
  }

  NSNumber* sharedKey = keyProviderOptions[@"sharedKey"];
  if (sharedKey == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateKeyProviderFailed"
                              message:@"Invalid sharedKey"
                              details:nil]);
    return;
  }

  NSData* ratchetSalt = WebrtcDataFromJsonArr(keyProviderOptions[@"ratchetSalt"]);
  if (ratchetSalt == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateKeyProviderFailed"
                              message:@"Invalid ratchetSalt"
                              details:nil]);
    return;
  }

  NSNumber* ratchetWindowSize = keyProviderOptions[@"ratchetWindowSize"];
  if (ratchetWindowSize == nil) {
    result([WebrtcError errorWithCode:@"frameCryptorFactoryCreateKeyProviderFailed"
                              message:@"Invalid ratchetWindowSize"
                              details:nil]);
    return;
  }

  NSNumber* failureTolerance = keyProviderOptions[@"failureTolerance"];

  NSData* uncryptedMagicBytes = WebrtcDataFromJsonArr(keyProviderOptions[@"uncryptedMagicBytes"]);

  NSNumber* keyRingSize = keyProviderOptions[@"keyRingSize"];

  NSNumber* discardFrameWhenCryptorNotReady = keyProviderOptions[@"discardFrameWhenCryptorNotReady"];

  RTCFrameCryptorKeyProvider* keyProvider =
      [[RTCFrameCryptorKeyProvider alloc] initWithRatchetSalt:ratchetSalt
                                           ratchetWindowSize:[ratchetWindowSize intValue]
                                               sharedKeyMode:[sharedKey boolValue]
                                         uncryptedMagicBytes:uncryptedMagicBytes
                                            failureTolerance:failureTolerance != nil ? [failureTolerance intValue] : -1
                                                 keyRingSize:keyRingSize != nil ? [keyRingSize intValue] : 0
                             discardFrameWhenCryptorNotReady:discardFrameWhenCryptorNotReady != nil ? [discardFrameWhenCryptorNotReady boolValue] : NO];
  self.keyProviders[keyProviderId] = keyProvider;
  result(@{@"keyProviderId" : keyProviderId});
}

- (RTCFrameCryptorKeyProvider*)getKeyProviderForId:(NSString*)keyProviderId
                                            result:(WebrtcResult)result {
  if (keyProviderId == nil) {
    result([WebrtcError errorWithCode:@"getKeyProviderForIdFailed"
                              message:@"Invalid keyProviderId"
                              details:nil]);
    return nil;
  }
  RTCFrameCryptorKeyProvider* keyProvider = self.keyProviders[keyProviderId];
  if (keyProvider == nil) {
    result([WebrtcError errorWithCode:@"getKeyProviderForIdFailed"
                              message:@"Invalid keyProvider"
                              details:nil]);
    return nil;
  }
  return keyProvider;
}

- (void)keyProviderSetSharedKey:(NSDictionary*)constraints result:(WebrtcResult)result {
  RTCFrameCryptorKeyProvider* keyProvider =
      [self getKeyProviderForId:constraints[@"keyProviderId"] result:result];
  if (keyProvider == nil) {
    return;
  }

  NSNumber* keyIndex = constraints[@"keyIndex"];
  if (keyIndex == nil) {
    result([WebrtcError errorWithCode:@"keyProviderSetKeyFailed"
                              message:@"Invalid keyIndex"
                              details:nil]);
    return;
  }

  NSData* key = WebrtcDataFromJsonArr(constraints[@"key"]);
  if (key == nil) {
    result([WebrtcError errorWithCode:@"keyProviderSetKeyFailed"
                              message:@"Invalid key"
                              details:nil]);
    return;
  }

  [keyProvider setSharedKey:key withIndex:[keyIndex intValue]];
  result(@{@"result" : @YES});
}

- (void)keyProviderRatchetSharedKey:(NSDictionary*)constraints result:(WebrtcResult)result {
  RTCFrameCryptorKeyProvider* keyProvider =
      [self getKeyProviderForId:constraints[@"keyProviderId"] result:result];
  if (keyProvider == nil) {
    return;
  }

  NSNumber* keyIndex = constraints[@"keyIndex"];
  if (keyIndex == nil) {
    result([WebrtcError errorWithCode:@"keyProviderRatchetSharedKeyFailed"
                              message:@"Invalid keyIndex"
                              details:nil]);
    return;
  }

  NSData* newKey = [keyProvider ratchetSharedKey:[keyIndex intValue]];
  result(@{@"result" : WebrtcJsonArrFromData(newKey)});
}

- (void)keyProviderExportSharedKey:(NSDictionary*)constraints result:(WebrtcResult)result {
  RTCFrameCryptorKeyProvider* keyProvider =
      [self getKeyProviderForId:constraints[@"keyProviderId"] result:result];
  if (keyProvider == nil) {
    return;
  }

  NSNumber* keyIndex = constraints[@"keyIndex"];
  if (keyIndex == nil) {
    result([WebrtcError errorWithCode:@"keyProviderExportSharedKeyFailed"
                              message:@"Invalid keyIndex"
                              details:nil]);
    return;
  }

  NSData* key = [keyProvider exportSharedKey:[keyIndex intValue]];
  result(@{@"result" : WebrtcJsonArrFromData(key)});
}

- (void)keyProviderSetKey:(NSDictionary*)constraints result:(WebrtcResult)result {
  RTCFrameCryptorKeyProvider* keyProvider =
      [self getKeyProviderForId:constraints[@"keyProviderId"] result:result];
  if (keyProvider == nil) {
    return;
  }

  NSNumber* keyIndex = constraints[@"keyIndex"];
  if (keyIndex == nil) {
    result([WebrtcError errorWithCode:@"keyProviderSetKeyFailed"
                              message:@"Invalid keyIndex"
                              details:nil]);
    return;
  }

  NSData* key = WebrtcDataFromJsonArr(constraints[@"key"]);
  if (key == nil) {
    result([WebrtcError errorWithCode:@"keyProviderSetKeyFailed"
                              message:@"Invalid key"
                              details:nil]);
    return;
  }

  NSString* participantId = constraints[@"participantId"];
  if (participantId == nil) {
    result([WebrtcError errorWithCode:@"keyProviderSetKeyFailed"
                              message:@"Invalid participantId"
                              details:nil]);
    return;
  }

  [keyProvider setKey:key withIndex:[keyIndex intValue] forParticipant:participantId];
  result(@{@"result" : @YES});
}

- (void)keyProviderRatchetKey:(NSDictionary*)constraints result:(WebrtcResult)result {
  RTCFrameCryptorKeyProvider* keyProvider =
      [self getKeyProviderForId:constraints[@"keyProviderId"] result:result];
  if (keyProvider == nil) {
    return;
  }

  NSNumber* keyIndex = constraints[@"keyIndex"];
  if (keyIndex == nil) {
    result([WebrtcError errorWithCode:@"keyProviderRatchetKeyFailed"
                              message:@"Invalid keyIndex"
                              details:nil]);
    return;
  }

  NSString* participantId = constraints[@"participantId"];
  if (participantId == nil) {
    result([WebrtcError errorWithCode:@"keyProviderRatchetKeyFailed"
                              message:@"Invalid participantId"
                              details:nil]);
    return;
  }

  NSData* newKey = [keyProvider ratchetKey:participantId withIndex:[keyIndex intValue]];
  result(@{@"result" : WebrtcJsonArrFromData(newKey)});
}

- (void)keyProviderExportKey:(NSDictionary*)constraints result:(WebrtcResult)result {
  RTCFrameCryptorKeyProvider* keyProvider =
      [self getKeyProviderForId:constraints[@"keyProviderId"] result:result];
  if (keyProvider == nil) {
    return;
  }

  NSNumber* keyIndex = constraints[@"keyIndex"];
  if (keyIndex == nil) {
    result([WebrtcError errorWithCode:@"keyProviderExportKeyFailed"
                              message:@"Invalid keyIndex"
                              details:nil]);
    return;
  }

  NSString* participantId = constraints[@"participantId"];
  if (participantId == nil) {
    result([WebrtcError errorWithCode:@"keyProviderExportKeyFailed"
                              message:@"Invalid participantId"
                              details:nil]);
    return;
  }

  NSData* key = [keyProvider exportKey:participantId withIndex:[keyIndex intValue]];
  result(@{@"result" : WebrtcJsonArrFromData(key)});
}

- (void)keyProviderSetSifTrailer:(NSDictionary*)constraints result:(WebrtcResult)result {
  RTCFrameCryptorKeyProvider* keyProvider =
      [self getKeyProviderForId:constraints[@"keyProviderId"] result:result];
  if (keyProvider == nil) {
    return;
  }

  NSData* sifTrailer = WebrtcDataFromJsonArr(constraints[@"sifTrailer"]);
  if (sifTrailer == nil) {
    result([WebrtcError errorWithCode:@"keyProviderSetSifTrailerFailed"
                              message:@"Invalid sifTrailer"
                              details:nil]);
    return;
  }

  [keyProvider setSifTrailer:sifTrailer];
  // darwin 原返回 nil, 这里对齐 win/linux C ABI 的 {"result":true} JSON 边界
  result(@{@"result" : @YES});
}

- (void)keyProviderDispose:(NSDictionary*)constraints result:(WebrtcResult)result {
  NSString* keyProviderId = constraints[@"keyProviderId"];
  if (keyProviderId == nil) {
    result([WebrtcError errorWithCode:@"getKeyProviderForIdFailed"
                              message:@"Invalid keyProviderId"
                              details:nil]);
    return;
  }
  [self.keyProviders removeObjectForKey:keyProviderId];
  result(@{@"result" : @"success"});
}

#pragma mark - RTCFrameCryptorDelegate(照抄 darwin; 状态经 factory 事件回调上报)

- (void)frameCryptor:(RTCFrameCryptor*)frameCryptor
    didStateChangeWithParticipantId:(NSString*)participantId
                          withState:(RTCFrameCryptorState)stateChanged {
  [self postFactoryEvent:@{
    @"event" : @"frameCryptionStateChanged",
    @"participantId" : participantId,
    @"state" : [self stringFromFrameCryptorState:stateChanged]
  }];
}

@end