//
//  XCPushDelegateProxy.h
//  MockNetPackKit
//
//  L5.1：XCPushSocket delegate 代理对象。
//
//  用 ObjC 承载的原因：通用消息兜底转发（forwardInvocation /
//  methodSignatureForSelector）在 Swift 中标记不可用（NSInvocation 相关
//  API 不可用），而"漏转发 = 破坏原逻辑"要求对 XCAsyncSocketDelegate 未来
//  新增回调也有兜底，故代理本体用 ObjC 实现，swizzle 逻辑在 Swift 侧。
//
//  职责：显式转发 XCAsyncSocketDelegate 全部 6 回调给原 delegate；
//  未显式实现的方法经 forwardInvocation 兜底转发（原 delegate 不响应则 no-op）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// XCPushSocket delegate 代理对象（weak 持有原 delegate，与
/// XCPushSocket.delegate 的 weak 语义一致，防循环引用）。
@interface XCPushDelegateProxy : NSObject

@property (nonatomic, weak, nullable) id originalDelegate;

- (instancetype)initWithOriginalDelegate:(nullable id)delegate;

// XCAsyncSocketDelegate 6 回调（显式转发，参数原样传给原 delegate；
// 原 delegate 未实现该回调时 no-op）。方法声明于此，Swift 侧方可直接调用。
- (void)asyncSocketDidConnect:(id)socket;
- (void)asyncSocket:(id)socket disconnectedWithError:(nullable NSError *)error;
- (void)socketDidCloseReadStream:(id)sock;
- (void)asyncSocket:(id)sock didReadTalk:(id)talk withTag:(long)tag;
- (void)asyncSocket:(id)socket timeoutReadWithTag:(long)tag;
- (void)asyncSocket:(id)socket timeoutWriteWithTag:(long)tag;

// L5.2 采集 hooks（旁路回调，不改变转发行为；Swift 侧注册采集器）。
// will/didForwardRead 分别于 didReadTalk 转发前/后调用（转发同步，
// 期间原 delegate 的处理栈内可触发 ACK 发送，采集器据此关联 ackSent）。
@property (nonatomic, copy, nullable) void (^didConnectHook)(id socket);
@property (nonatomic, copy, nullable) void (^disconnectedHook)(id socket, id _Nullable error);
@property (nonatomic, copy, nullable) void (^closeReadHook)(id sock);
@property (nonatomic, copy, nullable) void (^willForwardReadHook)(id sock, id talk, long tag);
@property (nonatomic, copy, nullable) void (^didForwardReadHook)(id sock, id talk, long tag);
@property (nonatomic, copy, nullable) void (^timeoutReadHook)(long tag);
@property (nonatomic, copy, nullable) void (^timeoutWriteHook)(long tag);

@end

NS_ASSUME_NONNULL_END
