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

// L7.2b 模拟推送注入（能力线 L7 模拟推送形态）：把构造好的假 Packet 当作
// 一次真实收包走完整转发链（willForwardReadHook → originalDelegate →
// didForwardReadHook），业务侧与真实推送零差异；不经过 XCPush 收包判重
// 路径（注入点根除，决策 D4：假 msgId 永不进 vReceivedMessageIds）。
// socket 为真实 XCPushSocket（sock 参数不能传 nil——业务 delegate 的
// 非可选签名会因 nil 崩溃，L7.2b 调试中实测 signal 11）。
//
// 线程对齐（真机崩溃 #3 修复）：真实收包在 XCPush socket 的 delegate queue
// 线程回调，业务在该线程做 Realm 等线程亲和数据写；注入若发生在心跳回调线程
// 直接同步转发 → RLMException "Realm accessed from incorrect thread"。
// 本方法先 dispatch_async 回「记录到的真实收包 queue」（连接/收包回调首次
// 到达时记录），在该 queue 上再走转发链——业务看到的执行线程与真实推送一致。
// willInject/didInject 在转发链前后于目标 queue 上同步执行（注入标记/解标记）。
- (void)injectFakeTalk:(id)talk
              onSocket:(id)socket
            willInject:(nullable void (^)(void))willInjectBlock
             didInject:(nullable void (^)(void))didInjectBlock;

/// 测试钩子：在测试主线程上记录当前 queue 为「收包 queue」，使注入派发
/// 可被 XCTestExpectation 等待（真机上由连接/收包回调自动记录）。
+ (void)mnp_recordCurrentReadQueueForTesting;

@end

NS_ASSUME_NONNULL_END
