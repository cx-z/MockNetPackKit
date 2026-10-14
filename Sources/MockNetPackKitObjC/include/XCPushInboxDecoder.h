//
//  XCPushInboxDecoder.h
//  MockNetPackKit
//
//  L5.6：XCPush bizData（解压后字节）→ 可读 JSON 文本（零侵入内置 coder）。
//
//  动态解码：不链接 FDSocketService，运行时 NSClassFromString("Sync") 探测并
//  GPB +parseFromData:error: 解包；解不出（非 protobuf 包）回退 JSONSerialization；
//  再失败返回 nil（调用方降级 base64，与一期 coder 语义一致）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把 XCPush bizData 字节解为可读 pretty-JSON 文本；不可解时返回 nil。
extern NSString *_Nullable MNPXCPushDecodeToJSON(NSData *raw);

NS_ASSUME_NONNULL_END
