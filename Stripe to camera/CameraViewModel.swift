import AVFoundation
import UIKit
import Combine
import Photos

final class CameraViewModel: NSObject, ObservableObject {
    @Published var filteredImage: UIImage?
    @Published var capturedImage: UIImage?

    private let session = AVCaptureSession()
    private let context = CIContext()
    private let glitch = GlitchSliceFilter()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "video.sample.buffer")

    override init() {
        super.init()
        configureSession()
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
        }
    }
    
    func captureStill() {
        // 現在表示中のフレームを静止画として保持し、アルバムに保存
        guard let image = self.filteredImage else { return }
        DispatchQueue.main.async {
            self.capturedImage = image
        }
        saveToPhotoLibrary(image)
    }

    // MARK: - 写真保存
    private func saveToPhotoLibrary(_ image: UIImage) {
        // iOS 14+ では .addOnly を優先
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:
                self.performSave(image)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    if newStatus == .authorized || newStatus == .limited {
                        self.performSave(image)
                    }
                }
            default:
                break
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            switch status {
            case .authorized:
                self.performSave(image)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization { newStatus in
                    if newStatus == .authorized {
                        self.performSave(image)
                    }
                }
            default:
                break
            }
        }
    }

    private func performSave(_ image: UIImage) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }, completionHandler: { _, _ in })
    }

    // MARK: - Session 設定
    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // 入力（背面カメラ）
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        // 出力
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                     kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        // 縦向き（Portrait）に固定 — 旧APIだけを使う
        if let conn = videoOutput.connections.first, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        session.commitConfiguration()
    }
}

// MARK: - デリゲート
extension CameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciInput = CIImage(cvPixelBuffer: buffer) // ← もう回転しない

        // フィルター適用（p5相当のパラメータを設定）
        glitch.inputImage = ciInput
        glitch.numOverlays = 120
        glitch.numBigSlices = 3
        glitch.minXSpan = 0.6
        glitch.maxXSpan = 5.0
        glitch.minYSpan = 0.6
        glitch.maxYSpan = 4.0
        glitch.spanPowerX = 2.5
        glitch.spanPowerY = 2.0
        glitch.biasRightOnly = 1
        glitch.time = CACurrentMediaTime() as NSNumber

        guard let ciOut = glitch.outputImage,
              let cg = context.createCGImage(ciOut, from: ciOut.extent) else { return }

        let ui = UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)

        DispatchQueue.main.async {
            self.filteredImage = ui
        }
    }
}
