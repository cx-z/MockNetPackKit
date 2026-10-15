//
//  XCPushDelegateProxy.m
//  MockNetPackKit
//
//  L5.1：XCPushSocket delegate 代理对象实现。
//  L5.2：转发前后触发采集 hooks（旁路，不改变转发行为），供 Swift 侧
//  XCPushLongConnRecorder 注册采集（收包字段映射 / 快照自维护 / ACK 关联）。
//
//  XCAsyncSocketDelegate 协议（FDSocketService/XCPushSocket.h）共 6 个可选回调：
//   asyncSocketDidConnect: / asyncSocket:disconnectedWithError: /
//   socketDidCloseReadStream: / asyncSocket:didReadTalk:withTag: /
//   asyncSocket:timeoutReadWithTag: / asyncSocket:timeoutWriteWithTag:
// 全部显式转发（漏转发 = 破坏原逻辑，必须全覆盖）；协议外/未来新增回调
// 经 respondsToSelector/methodSignatureForSelector/forwardInvocation 兜底。
//

#import "XCPushDelegateProxy.h"

/// 记录「真实收包上下文」的 dispatch queue（真机崩溃 #3 修复）。
/// 真实收包回调发生在 XCPush socket 的 delegate queue 线程上，业务在该
/// 线程做 Realm 等线程亲和数据写；模拟推送注入原本在心跳回调线程直接同步
/// 转发 → 业务在错误线程访问 Realm → RLMException。
/// 连接成功/收包回调首次到达时记录该 queue，注入时 dispatch_async 回此
/// queue 再走转发链，业务看到的执行线程与真实推送完全一致。
static dispatch_queue_t MNPRecordedReadQueue = NULL;

static void MNPRecordCurrentReadQueue(void) {
    if (MNPRecordedReadQueue) { return; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    dispatch_queue_t current = dispatch_get_current_queue();
#pragma clang diagnostic pop
    if (current) {
        MNPRecordedReadQueue = current;  // ARC：静态 strong 赋值即持有
    }
}

@implementation XCPushDelegateProxy

- (instancetype)initWithOriginalDelegate:(id)delegate {
    self = [super init];
    if (self) {
        _originalDelegate = delegate;
    }
    return self;
}

#pragma mark - XCAsyncSocketDelegate 显式转发（6 回调全覆盖，转发前后旁路采集 hook）

/// 连接成功。
- (void)asyncSocketDidConnect:(id)socket {
    // 连接成功回调也在 socket delegate queue 上发生——比首包更早记录 queue，
    // 覆盖「连上后尚未收包即注入」的场景。
    MNPRecordCurrentReadQueue();
    if (self.didConnectHook) {
        self.didConnectHook(socket);
    }
    if ([self.originalDelegate respondsToSelector:@selector(asyncSocketDidConnect:)]) {
        [self.originalDelegate asyncSocketDidConnect:socket];
    }
}

/// 连接断开/失败。
- (void)asyncSocket:(id)socket disconnectedWithError:(NSError *)error {
    if (self.disconnectedHook) {
        self.disconnectedHook(socket, error);
    }
    if ([self.originalDelegate respondsToSelector:@selector(asyncSocket:disconnectedWithError:)]) {
        [self.originalDelegate asyncSocket:socket disconnectedWithError:error];
    }
}

/// 读流关闭。
- (void)socketDidCloseReadStream:(id)sock {
    if (self.closeReadHook) {
        self.closeReadHook(sock);
    }
    if ([self.originalDelegate respondsToSelector:@selector(socketDidCloseReadStream:)]) {
        [self.originalDelegate socketDidCloseReadStream:sock];
    }
}

/// 收包（核心）。will/didForward 分别在转发前/后触发；转发同步进行，
/// 原 delegate 处理栈内可能触发 ACK 发送（send:tag: swizzle），
/// 采集器据此把 ackSent 关联到本次收包。
- (void)asyncSocket:(id)sock didReadTalk:(id)talk withTag:(long)tag {
    MNPRecordCurrentReadQueue();
    if (self.willForwardReadHook) {
        self.willForwardReadHook(sock, talk, tag);
    }
    if ([self.originalDelegate respondsToSelector:@selector(asyncSocket:didReadTalk:withTag:)]) {
        [self.originalDelegate asyncSocket:sock didReadTalk:talk withTag:tag];
    }
    if (self.didForwardReadHook) {
        self.didForwardReadHook(sock, talk, tag);
    }
}

/// 读超时。
- (void)asyncSocket:(id)socket timeoutReadWithTag:(long)tag {
    if (self.timeoutReadHook) {
        self.timeoutReadHook(tag);
    }
    if ([self.originalDelegate respondsToSelector:@selector(asyncSocket:timeoutReadWithTag:)]) {
        [self.originalDelegate asyncSocket:socket timeoutReadWithTag:tag];
    }
}

/// 写超时。
- (void)asyncSocket:(id)socket timeoutWriteWithTag:(long)tag {
    if (self.timeoutWriteHook) {
        self.timeoutWriteHook(tag);
    }
    if ([self.originalDelegate respondsToSelector:@selector(asyncSocket:timeoutWriteWithTag:)]) {
        [self.originalDelegate asyncSocket:socket timeoutWriteWithTag:tag];
    }
}

#pragma mark - 兜底转发（未来新增回调 / 协议外方法）

- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) {
        return YES;
    }
    return [self.originalDelegate respondsToSelector:aSelector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature *sig = [super methodSignatureForSelector:aSelector];
    if (sig) {
        return sig;
    }
    return [self.originalDelegate methodSignatureForSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    if ([self.originalDelegate respondsToSelector:anInvocation.selector]) {
        [anInvocation invokeWithTarget:self.originalDelegate];
    }
    // 原 delegate 不响应 → no-op，不崩溃。
}

#pragma mark - L7.2b 模拟推送注入

/// 测试钩子：记录当前 queue 为收包 queue（真机由连接/收包回调自动记录）。
+ (void)mnp_recordCurrentReadQueueForTesting {
    MNPRecordCurrentReadQueue();
}

/// 注入假收包：dispatch_async 回记录的真实收包 queue 后走 didReadTalk 全
/// 转发链（hooks + originalDelegate）。sock 传真实 XCPushSocket——
/// 业务 delegate 的非可选签名对 nil 敏感（L7.2b 实测 signal 11）。
- (void)injectFakeTalk:(id)talk
              onSocket:(id)socket
            willInject:(void (^ _Nullable)(void))willInjectBlock
             didInject:(void (^ _Nullable)(void))didInjectBlock {
    // 未记录过（测试/极端早注入）→ 主队列兜底。
    dispatch_queue_t q = MNPRecordedReadQueue ?: dispatch_get_main_queue();
    dispatch_async(q, ^{
        if (willInjectBlock) { willInjectBlock(); }
        [self asyncSocket:socket didReadTalk:talk withTag:0];
        if (didInjectBlock) { didInjectBlock(); }
    });
}

@end
