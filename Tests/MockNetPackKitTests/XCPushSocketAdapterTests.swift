//
//  XCPushSocketAdapterTests.swift
//  MockNetPackKitTests
//
//  L5.1 验收：代理转发单测覆盖全部回调（漏转发 = 破坏原逻辑，必须全覆盖）。
//
//  覆盖：
//  1. 6 回调全覆盖转发（参数/对象/次数/顺序一致）；
//  2. 原 delegate 未实现回调 → no-op 不崩溃；
//  3. swizzle 后 XCPushSocket 侧 delegate == proxy（原 delegate 不再直连）；
//  4. 同一 socket 重复 setDelegate: 幂等（不嵌套包裹、原 delegate 引用更新）；
//  5. 协议外/新增回调经 forwardInvocation 自动转发；
//  6. 类未加载时 install no-op 不崩溃；重复 install 幂等。
//
//  基座不依赖 FDSocketService：FakeXCPushSocket 模仿 XCPushSocket 的
//  weak delegate property（自动合成 setDelegate:），记录型 fake delegate 记录调用。
//

import Foundation
import XCTest
import MockNetPackKitObjC
@testable import MockNetPackKit

/// 模仿 XCPushSocket 的 delegate 承载类（@objc weak property → 自动合成 setDelegate:）。
/// 显式 @objc 名：Swift @objc 类默认以"模块名.类名"注册 ObjC runtime，
/// 而生产目标 XCPushSocket 是 ObjC 类（纯类名），NSClassFromString 需按纯类名匹配。
/// L5.2：追加路由/心跳/发送方法（供适配器 swizzle 与调用记录验证）。
@objc(FakeXCPushSocket) final class FakeXCPushSocket: NSObject {
    @objc weak var delegate: AnyObject?

    // L5.2 调用记录（原实现被调用则记录）
    var connectHost: String?
    var connectPort: UInt16?
    var heartbeatInterval: Double?
    var heartbeatStopped = false
    var heartbeatSentCount = 0
    var sentTags: [Int] = []
    var sentData: [AnyObject] = []

    @objc func connectToHost(_ host: String, onPort port: UInt16) {
        connectHost = host
        connectPort = port
    }

    @objc func startHeartbeatWithTimeInterval(_ interval: Double) {
        heartbeatInterval = interval
    }

    @objc func stopHeartbeat() {
        heartbeatStopped = true
    }

    @objc func sendHeartbeatPacket() {
        heartbeatSentCount += 1
    }

    @objc func send(_ data: AnyObject, tag: Int) {
        sentTags.append(tag)
        sentData.append(data)
    }
}

/// 记录型 fake delegate：实现 XCAsyncSocketDelegate 全部 6 回调 + 1 个协议外方法。
@objc final class RecordingDelegate: NSObject {
    struct Call {
        let name: String
        let args: [Any?]
    }
    var calls: [Call] = []
    var connectedSocket: AnyObject?
    var disconnectedSocket: AnyObject?
    var disconnectedError: AnyObject?
    var closedSocket: AnyObject?
    var readSocket: AnyObject?
    var readTalk: AnyObject?
    var readTag: Int?
    var readTimeoutSocket: AnyObject?
    var readTimeoutTag: Int?
    var writeTimeoutSocket: AnyObject?
    var writeTimeoutTag: Int?
    var futureArg: AnyObject?

    @objc func asyncSocketDidConnect(_ socket: AnyObject) {
        calls.append(Call(name: "didConnect", args: [socket]))
        connectedSocket = socket
    }

    @objc func asyncSocket(_ socket: AnyObject, disconnectedWithError error: AnyObject?) {
        calls.append(Call(name: "disconnected", args: [socket, error as Any]))
        disconnectedSocket = socket
        disconnectedError = error
    }

    @objc func socketDidCloseReadStream(_ sock: AnyObject) {
        calls.append(Call(name: "closeRead", args: [sock]))
        closedSocket = sock
    }

    @objc func asyncSocket(_ sock: AnyObject, didReadTalk talk: AnyObject, withTag tag: Int) {
        calls.append(Call(name: "didReadTalk", args: [sock, talk, tag]))
        readSocket = sock
        readTalk = talk
        readTag = tag
    }

    @objc func asyncSocket(_ socket: AnyObject, timeoutReadWithTag tag: Int) {
        calls.append(Call(name: "timeoutRead", args: [socket, tag]))
        readTimeoutSocket = socket
        readTimeoutTag = tag
    }

    @objc func asyncSocket(_ socket: AnyObject, timeoutWriteWithTag tag: Int) {
        calls.append(Call(name: "timeoutWrite", args: [socket, tag]))
        writeTimeoutSocket = socket
        writeTimeoutTag = tag
    }

    /// 协议外方法（forwardInvocation 兜底目标）。
    @objc func futureCallback(_ obj: AnyObject) {
        futureArg = obj
    }
}

/// 部分实现 delegate：只实现 didConnect 与 didReadTalk（其余回调未实现）。
@objc final class PartialDelegate: NSObject {
    @objc func asyncSocketDidConnect(_ socket: AnyObject) {}
    @objc func asyncSocket(_ sock: AnyObject, didReadTalk talk: AnyObject, withTag tag: Int) {}
}

final class XCPushSocketAdapterTests: XCTestCase {

    // MARK: - 验收 1：6 回调全覆盖转发（参数/对象/次数/顺序一致）

    func testProxyForwardsAllSixCallbacksWithExactArgs() {
        let delegate = RecordingDelegate()
        let proxy = XCPushDelegateProxy(originalDelegate: delegate)
        let socket = FakeXCPushSocket()

        proxy.asyncSocketDidConnect(socket)
        XCTAssertTrue(delegate.connectedSocket === socket)

        let error = NSError(domain: "test", code: 1)
        proxy.asyncSocket(socket, disconnectedWithError: error)
        XCTAssertTrue(delegate.disconnectedSocket === socket)
        XCTAssertTrue(delegate.disconnectedError as? NSError === error)

        proxy.socketDidCloseReadStream(socket)
        XCTAssertTrue(delegate.closedSocket === socket)

        let talk = NSObject()
        proxy.asyncSocket(socket, didReadTalk: talk, withTag: 101)
        XCTAssertTrue(delegate.readSocket === socket)
        XCTAssertTrue(delegate.readTalk === talk)
        XCTAssertEqual(delegate.readTag, 101)

        proxy.asyncSocket(socket, timeoutReadWithTag: 0)
        XCTAssertTrue(delegate.readTimeoutSocket === socket)
        XCTAssertEqual(delegate.readTimeoutTag, 0)

        proxy.asyncSocket(socket, timeoutWriteWithTag: 7)
        XCTAssertTrue(delegate.writeTimeoutSocket === socket)
        XCTAssertEqual(delegate.writeTimeoutTag, 7)

        // 次数与顺序（XCPushSocket.m 的调用序：didConnect → disconnected → closeRead → didReadTalk → timeoutRead → timeoutWrite）
        XCTAssertEqual(delegate.calls.count, 6)
        XCTAssertEqual(delegate.calls.map(\.name),
                       ["didConnect", "disconnected", "closeRead", "didReadTalk", "timeoutRead", "timeoutWrite"])
    }

    // MARK: - 验收 2：原 delegate 未实现回调 → no-op 不崩溃

    func testProxyNoOpWhenOriginalMissingMethod() {
        let partial = PartialDelegate()
        let proxy = XCPushDelegateProxy(originalDelegate: partial)
        let socket = FakeXCPushSocket()

        // 原 delegate 未实现：不转发、不崩溃
        proxy.socketDidCloseReadStream(socket)
        proxy.asyncSocket(socket, timeoutReadWithTag: 1)
        proxy.asyncSocket(socket, timeoutWriteWithTag: 1)
        proxy.asyncSocket(socket, disconnectedWithError: nil)
    }

    // MARK: - 边界：原 delegate 为 nil → 不转发不崩溃

    func testProxyDoesNotForwardToNilOriginal() {
        let proxy = XCPushDelegateProxy(originalDelegate: nil)
        let socket = FakeXCPushSocket()
        proxy.asyncSocketDidConnect(socket)
        proxy.asyncSocket(socket, didReadTalk: NSObject(), withTag: 3)
        proxy.socketDidCloseReadStream(socket)
    }

    // MARK: - 验收 5：responds / forwardInvocation 兜底

    func testRespondsToSelectorMirrorsOriginal() {
        let delegate = RecordingDelegate()
        let proxy = XCPushDelegateProxy(originalDelegate: delegate)

        // 显式实现的方法：super 即应答
        XCTAssertTrue(proxy.responds(to: #selector(RecordingDelegate.asyncSocket(_:didReadTalk:withTag:))))
        // 仅原 delegate 实现的方法：透传应答
        XCTAssertTrue(proxy.responds(to: #selector(RecordingDelegate.futureCallback(_:))))
    }

    func testRespondsToSelectorFalseWhenOriginalMissing() {
        let partial = PartialDelegate()
        let proxy = XCPushDelegateProxy(originalDelegate: partial)
        // partial 未实现协议外方法 futureCallback: → proxy 不应答
        // （6 个协议回调 proxy 均显式实现，恒应答，不在此列）
        XCTAssertFalse(proxy.responds(to: #selector(RecordingDelegate.futureCallback(_:))))
    }

    func testForwardInvocationFallbackForUnknownSelector() {
        let delegate = RecordingDelegate()
        let proxy = XCPushDelegateProxy(originalDelegate: delegate)
        let obj = NSObject()
        _ = proxy.perform(#selector(RecordingDelegate.futureCallback(_:)), with: obj)
        XCTAssertTrue(delegate.futureArg === obj, "协议外方法应经 forwardInvocation 转发给原 delegate")
    }

    // MARK: - 验收 3：swizzle 后 delegate == proxy，转发链路完整
    //
    // 注：真实场景 XCPushSocket 为 ObjC 类，业务侧 Swift 赋值 `socket.delegate = x`
    // 必走 ObjC 消息派发（objc_msgSend setDelegate:），swizzle 生效。测试的
    // FakeXCPushSocket 是 Swift 类，Swift 语法赋值会直接调用合成 setter、绕过
    // ObjC 消息派发，故测试统一用 perform 触发 setDelegate: 模拟 ObjC 消息派发。

    private func setDelegate(of socket: FakeXCPushSocket, to delegate: AnyObject?) {
        let setter = NSSelectorFromString("setDelegate:")
        _ = socket.perform(setter, with: delegate)
    }

    func testSwizzleInstallsProxyAndForwards() {
        let socket = FakeXCPushSocket()
        let delegate = RecordingDelegate()

        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")
        setDelegate(of: socket, to: delegate)

        let proxy = socket.delegate as? XCPushDelegateProxy
        XCTAssertNotNil(proxy, "setDelegate: 后 XCPushSocket 侧 delegate 应为 proxy")
        XCTAssertTrue(proxy?.originalDelegate === delegate, "proxy 应持有原 delegate")

        // 业务侧触发（等价于 XCPushSocket 调 proxy 回调）→ 完整转发
        proxy?.asyncSocketDidConnect(socket)
        XCTAssertTrue(delegate.connectedSocket === socket)

        let talk = NSObject()
        proxy?.asyncSocket(socket, didReadTalk: talk, withTag: 42)
        XCTAssertTrue(delegate.readTalk === talk)
        XCTAssertEqual(delegate.readTag, 42)

        // 原 delegate 不再直连
        XCTAssertFalse(socket.delegate === delegate)
    }

    // MARK: - 验收 4：同一 socket 重复 setDelegate: 幂等

    func testRepeatedSetDelegateIsIdempotent() {
        let socket = FakeXCPushSocket()
        let d1 = RecordingDelegate()
        let d2 = RecordingDelegate()

        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")
        setDelegate(of: socket, to: d1)
        let proxy1 = socket.delegate as? XCPushDelegateProxy
        XCTAssertTrue(proxy1?.originalDelegate === d1)

        setDelegate(of: socket, to: d2)
        let proxy2 = socket.delegate as? XCPushDelegateProxy
        XCTAssertTrue(proxy2 === proxy1, "重复 setDelegate: 复用同一 proxy，不嵌套包裹")
        XCTAssertTrue(proxy2?.originalDelegate === d2, "原 delegate 引用更新为最新")
    }

    // MARK: - nil 透传

    func testSetDelegateNilPassesThrough() {
        let socket = FakeXCPushSocket()
        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")
        setDelegate(of: socket, to: nil)
        XCTAssertNil(socket.delegate)
    }

    // MARK: - 验收 6：类未加载 no-op；重复 install 幂等

    func testInstallNoOpWhenClassMissing() {
        // 不崩溃；未置位安装标志（后续真实类安装不受影响）
        XCPushSocketAdapter.installIfNeeded(className: "NoSuchClass_XYZ_42")
    }

    func testInstallIsIdempotent() {
        let socket = FakeXCPushSocket()
        let delegate = RecordingDelegate()

        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")
        XCPushSocketAdapter.installIfNeeded(className: "FakeXCPushSocket")   // 第二次 no-op

        setDelegate(of: socket, to: delegate)
        let proxy = socket.delegate as? XCPushDelegateProxy
        XCTAssertTrue(proxy?.originalDelegate === delegate)
    }
}
