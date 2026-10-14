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

@end
