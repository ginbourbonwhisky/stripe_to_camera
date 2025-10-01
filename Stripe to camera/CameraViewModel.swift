import AVFoundation
import UIKit
import Combine
import Photos

final class CameraViewModel: NSObject, ObservableObject {
    @Published var filteredImage: UIImage?
    @Published var capturedImage: UIImage?
    @Published var originalImage: UIImage?

    private let session = AVCaptureSession()
    private let context = CIContext()
    private let glitch = GlitchSliceFilter()

    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "video.sample.buffer")

    // stripe001: 行セグメント（明度/彩度差分で横方向に再構成）
    // - 調整ポイント:
    //   brightnessThreshold: 明度差のしきい値（下げる=検出増）
    //   saturationThreshold: 彩度差のしきい値（下げる=検出増）
    //   yDivisions: 帯の本数（上げる=細く/重い, 下げる=太く/軽い）
    private let brightnessThreshold: Float = 28
    private let saturationThreshold: Float = 35
    private let yDivisions: Int = 110

    // stripe002: 縦帯分割（仮想xをランダム分割して左端の色で塗る）
    // - 調整ポイント:
    //   targetBands: 帯の本数（例: 50）。増やす=細かく/重い
    //   borderAlpha: 境界の見せ方（0=非表示, 0.0〜1.0）
    private let targetBands002: Int = 50
    private let borderAlpha002: CGFloat = 0.0
    private var xVirtualPoints002: [CGFloat] = []   // -10..+10 の内部点
    private var didSeedStripe002 = false

    // フィルタ切替: true=stripe001, false=stripe002（必要ならUI側から切替）
    var useStripe001: Bool = true

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

        // オリジナル（フィルタ無）UI画像
        let baseCI = ciInput
        guard let baseCG = context.createCGImage(baseCI, from: baseCI.extent) else { return }
        let original = UIImage(cgImage: baseCG, scale: UIScreen.main.scale, orientation: .up)

        // フィルタ適用後
        guard let ciOut = glitch.outputImage,
              let cg = context.createCGImage(ciOut, from: ciOut.extent) else {
            DispatchQueue.main.async {
                self.originalImage = original
            }
            return
        }

        let ui = UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)

        if useStripe001 {
            // stripe001: 明度/彩度の変化で横方向にセグメント化
            if let banded = applyRowSegmentEffect(to: ui,
                                                  brightnessThreshold: brightnessThreshold,
                                                  saturationThreshold: saturationThreshold,
                                                  yDivisions: yDivisions) {
                DispatchQueue.main.async {
                    self.originalImage = original
                    self.filteredImage = banded
                }
                return
            }
        } else {
            // stripe002: ランダム分割の縦帯（左端色で塗る）
            if let banded = applyVerticalBandEffect002(to: ui,
                                                       targetBands: targetBands002,
                                                       borderAlpha: borderAlpha002) {
                DispatchQueue.main.async {
                    self.originalImage = original
                    self.filteredImage = banded
                }
                return
            }
        }
        DispatchQueue.main.async {
            self.originalImage = original
            self.filteredImage = ui
        }
    }
}

// MARK: - p5風 行セグメント効果（CPU描画）
private extension CameraViewModel {
    func applyRowSegmentEffect(to image: UIImage,
                               brightnessThreshold: Float,
                               saturationThreshold: Float,
                               yDivisions: Int) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        // 入力ピクセルをRGBA8で取得
        guard let inData = copyRGBAData(from: cgImage) else { return nil }

        // 出力コンテキスト
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 上原点（UIKit準拠）に座標系を反転
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let bandHf = CGFloat(height) / CGFloat(max(1, yDivisions))

        // 各帯ごとに1ラインサンプリングし、分割点を求めて矩形で塗る
        for yi in 0..<max(1, yDivisions) {
            // 上原点のままサンプリング（0=上端）
            let yImg = min(height - 1, Int((Float(yi) + 0.5) / Float(yDivisions) * Float(height)))

            // 先頭画素
            var prev = rgbAt(inData: inData, x: 0, y: yImg, width: width)
            var prevHSB = rgbToHSB(prev)
            var points: [Int] = [0]

            if width > 1 {
                for x in 1..<width {
                    let cur = rgbAt(inData: inData, x: x, y: yImg, width: width)
                    let curHSB = rgbToHSB(cur)
                    let db = abs(curHSB.brightness - prevHSB.brightness) * 100.0
                    let ds = abs(curHSB.saturation - prevHSB.saturation) * 100.0
                    if db > brightnessThreshold || ds > saturationThreshold {
                        points.append(x)
                        prev = cur
                        prevHSB = curHSB
                    }
                }
            }
            points.append(width)

            // 区間を矩形で描く
            for i in 0..<(points.count - 1) {
                let xStart = points[i]
                let xEnd = points[i + 1]
                let colorRGB = rgbAt(inData: inData, x: xStart, y: yImg, width: width)
                ctx.setFillColor(CGColor(
                    srgbRed: CGFloat(colorRGB.r) / 255.0,
                    green: CGFloat(colorRGB.g) / 255.0,
                    blue: CGFloat(colorRGB.b) / 255.0,
                    alpha: 1.0
                ))
                let xCanvas = CGFloat(xStart)
                let bandW = CGFloat(xEnd - xStart)
                // 上原点でそのまま描画
                let yCanvasTop = CGFloat(yi) * bandHf
                ctx.fill(CGRect(x: xCanvas, y: yCanvasTop, width: bandW, height: bandHf))
            }
        }

        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: .up)
    }

    struct RGB { var r: UInt8; var g: UInt8; var b: UInt8 }

    func copyRGBAData(from cgImage: CGImage) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var data = Data(count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(data: ptr.baseAddress,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return data
    }

    func rgbAt(inData: Data, x: Int, y: Int, width: Int) -> RGB {
        let idx = (y * width + x) * 4
        let r = inData[idx]
        let g = inData[idx + 1]
        let b = inData[idx + 2]
        return RGB(r: r, g: g, b: b)
    }

    func rgbToHSB(_ c: RGB) -> (hue: Float, saturation: Float, brightness: Float) {
        let rf = Float(c.r) / 255.0
        let gf = Float(c.g) / 255.0
        let bf = Float(c.b) / 255.0
        let maxv = max(rf, gf, bf)
        let minv = min(rf, gf, bf)
        let delta = maxv - minv
        let brightness = maxv
        let saturation = maxv == 0 ? 0 : (delta / maxv)
        var hue: Float = 0
        if delta != 0 {
            if maxv == rf {
                hue = (gf - bf) / delta
            } else if maxv == gf {
                hue = 2 + (bf - rf) / delta
            } else {
                hue = 4 + (rf - gf) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, saturation, brightness)
    }

    // MARK: - stripe002 縦帯分割（ランダムな仮想xの内部点で分割し、左端色で塗る）
    func applyVerticalBandEffect002(to image: UIImage,
                                    targetBands: Int,
                                    borderAlpha: CGFloat) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        // 入力ピクセルRGBA8
        guard let inData = copyRGBAData(from: cgImage) else { return nil }

        // 初期化: 仮想xの内部点をランダム生成（-10..+10）
        if !didSeedStripe002 || xVirtualPoints002.isEmpty {
            let internalPoints = max(0, targetBands - 1)
            var pts: [CGFloat] = []
            pts.reserveCapacity(internalPoints)
            for _ in 0..<internalPoints {
                let v = CGFloat.random(in: -10...10)
                pts.append(v)
            }
            pts.sort()
            xVirtualPoints002 = pts
            didSeedStripe002 = true
        }

        // 出力コンテキスト（上原点に反転）
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // 分割点（端点を追加）
        var points: [CGFloat] = [-10]
        points.append(contentsOf: xVirtualPoints002)
        points.append(10)

        for i in 0..<(points.count - 1) {
            let xStartVirt = points[i]
            let xEndVirt = points[i + 1]

            // 左端の色（xImg）
            let xImgVirt = xStartVirt
            let xImg = max(0, min(width - 1, Int((xImgVirt + 10) / 20 * CGFloat(width - 1))))

            let xStartPx = (xStartVirt + 10) / 20 * CGFloat(width)
            let xEndPx = (xEndVirt + 10) / 20 * CGFloat(width)
            let bandW = xEndPx - xStartPx

            // 帯塗り（1pxずつ縦に）
            for y in 0..<height {
                let colorRGB = rgbAt(inData: inData, x: xImg, y: y, width: width)
                ctx.setFillColor(CGColor(
                    srgbRed: CGFloat(colorRGB.r) / 255.0,
                    green: CGFloat(colorRGB.g) / 255.0,
                    blue: CGFloat(colorRGB.b) / 255.0,
                    alpha: 1.0
                ))
                ctx.fill(CGRect(x: xStartPx, y: CGFloat(y), width: bandW, height: 1))
            }

            // 境界線（オプション）
            if borderAlpha > 0 && i < points.count - 2 {
                let midY = height / 2
                let edgeRGB = rgbAt(inData: inData, x: xImg, y: midY, width: width)
                let r = CGFloat(edgeRGB.r) * 0.6 / 255.0
                let g = CGFloat(edgeRGB.g) * 0.6 / 255.0
                let b = CGFloat(edgeRGB.b) * 0.6 / 255.0
                ctx.setStrokeColor(CGColor(srgbRed: r, green: g, blue: b, alpha: borderAlpha))
                ctx.setLineWidth(1)
                ctx.stroke(CGRect(x: xEndPx, y: 0, width: 0, height: CGFloat(height)))
            }
        }

        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: .up)
    }
}
