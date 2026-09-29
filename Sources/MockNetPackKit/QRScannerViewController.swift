import Foundation

/// 扫码错误（M9.2）。
enum QRScanError: Error, Equatable {
    /// 相机不可用（模拟器/无摄像头/无法配置采集会话）。
    case cameraUnavailable
    /// 用户拒绝相机权限。
    case cameraDenied
}

/// 扫码结果提供协议（M9.2）：真实实现为 `QRScannerViewController`（AVCaptureSession），
/// 测试注入 mock 返回预置二维码文本。协议 @MainActor：扫码 UI 只在主线程触碰。
@MainActor
protocol QRScanProviding: Sendable {
    /// 发起扫码并异步返回二维码文本；返回 nil 表示用户取消。
    func scanQRCode() async throws -> String?
}

#if canImport(UIKit)
// AVFoundation 未声明 Sendable，但 AVCaptureSession 可从后台线程操作
// （startRunning 阻塞调用）；@preconcurrency 将 Sendable 相关检查降级为警告。
@preconcurrency import AVFoundation
import UIKit

/// 原生相机扫码视图控制器（M9.2，D2/D3 拍板：原生实现、集成进 SDK、iOS 15 兼容）。
///
/// 内部：AVCaptureSession + AVCaptureMetadataOutput(.qr)，识别到第一个二维码即回调；
/// 相机权限：首次 requestAccess，拒绝 → `.cameraDenied`；无摄像头（模拟器）→ `.cameraUnavailable`。
/// 以模态方式 present 在调用方视图控制器上，带「取消」按钮。
final class QRScannerViewController: UIViewController, @unchecked Sendable, QRScanProviding {

    private let presenter: UIViewController
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var continuation: CheckedContinuation<String?, Error>?
    private var finished = false

    /// - Parameter presenter: 用于 present 本扫码界面的视图控制器。
    init(presentingFrom presenter: UIViewController) {
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - QRScanProviding

    func scanQRCode() async throws -> String? {
        // 1) 相机权限（首次弹窗；拒绝 → cameraDenied）。
        let granted = try await Self.requestCameraAccess()
        guard granted else { throw QRScanError.cameraDenied }

        // 2) 配置采集会话（模拟器无摄像头 → cameraUnavailable）。
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw QRScanError.cameraUnavailable
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { throw QRScanError.cameraUnavailable }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        // 3) present 并等待扫码结果（首个二维码 / 取消）。
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            self.continuation = continuation
            presenter.present(self, animated: true) { [weak self] in
                self?.startSession()
            }
        }
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        // 顶部取消按钮。
        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17)
        cancel.setTitleColor(.white, for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    @objc private func cancelTapped() {
        finish(nil)
    }

    /// 结束扫码并恢复等待方；幂等（防止 delegate 与取消按钮双触发）。
    /// M9.3-fix：先收起扫码面板（dismiss 前置），再恢复等待方——面板收起不依赖
    /// 后续连接逻辑；再由调用方在流程结束时兜底 dismissIfPresented() 防静默失败。
    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        session.stopRunning()
        dismiss(animated: true)
        continuation?.resume(returning: value)
        continuation = nil
    }

    /// 兜底收起（M9.3-fix）：扫码流程结束（成功/失败）后由调用方调用；
    /// 面板仍在窗口上（扫码完成但 dismiss 因竞态未生效）时才 dismiss，幂等安全。
    func dismissIfPresented() {
        guard !finished, view.window != nil else { return }
        finished = true
        session.stopRunning()
        dismiss(animated: true)
    }

    private func startSession() {
        // startRunning 是阻塞调用，放后台队列；预览由预览层自动渲染。
        // 后台闭包不得触碰 @MainActor 隔离属性：先快照 session/finished，
        // 再以弱引用保留「控制器已释放则不再启动采集」的语义。
        let session = self.session
        let finished = self.finished
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard !finished else { return }
            guard self != nil else { return }
            session.startRunning()
        }
    }

    private static func requestCameraAccess() async throws -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        // delegate 队列固定为 .main（setMetadataObjectsDelegate(_:queue:)），回调必然
        // 落在主线程；但 conformance 对协议而言是 nonisolated，须显式回到 MainActor
        // 再触碰 @MainActor 隔离状态（finish/continuation）。先取出 Sendable 的
        // 二维码文本，避免把非 Sendable 的 metadataObjects 传入闭包。
        let value = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .first?.stringValue
        MainActor.assumeIsolated {
            guard let value else { return }
            finish(value)
        }
    }
}
#endif
