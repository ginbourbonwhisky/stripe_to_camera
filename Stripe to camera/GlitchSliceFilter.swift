import CoreImage
import CoreImage.CIFilterBuiltins

/// 横スライスずらしを「CIDisplacementDistortion」で再現するフィルタ
/// - 赤チャンネル=水平方向の変位、緑チャンネル=垂直方向の変位
/// - 乱数テクスチャを横方向に強くブラーして「行ごとにほぼ一定のオフセット」を作る
final class GlitchSliceFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    /// 行数イメージの粗さ（数値が大きいほど“帯”が細かい）
    @objc dynamic var sliceCount: NSNumber = 120
    /// ときどき大きい帯を混ぜる比率（0〜1、見た目寄せ用・簡易）
    @objc dynamic var bigSliceCount: NSNumber = 3   // 未使用でも互換のため残す
    /// 横ずれ量の最小スパン（見た目の強さ・下限）
    @objc dynamic var minXSpan: NSNumber = 0.6
    /// 横ずれ量の最大スパン（見た目の強さ・上限）
    @objc dynamic var maxXSpan: NSNumber = 5.0
    /// 縦方向の伸縮感（弱いスケーリングに使うが、ここでは微弱ノイズに置換）
    @objc dynamic var minYSpan: NSNumber = 0.6
    @objc dynamic var maxYSpan: NSNumber = 4.0
    /// アニメーション用の時刻（秒）
    @objc dynamic var time: NSNumber = 0.0

    // p5相当の追加パラメータ
    @objc dynamic var numOverlays: NSNumber = 120      // 小スライス本数（p5: numOverlays）
    @objc dynamic var numBigSlices: NSNumber = 3       // 大スライス本数（p5: numBigSlices）
    @objc dynamic var spanPowerX: NSNumber = 2.5       // 横スパンのバイアス（小さい値を多く）
    @objc dynamic var spanPowerY: NSNumber = 2.0       // 縦スパンのバイアス（参考値）
    @objc dynamic var biasRightOnly: NSNumber = 1      // 右方向のみ（1: 有効, 0: 双方向）

    private let context = CIContext(options: nil)

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        let extent = input.extent
        let W = extent.width
        let H = extent.height

        // 1) ノイズ生成
        let noise = CIFilter.randomGenerator().outputImage!
            .cropped(to: extent)

        // 2) ノイズを横方向に強くにじませ、各行でほぼ一定の値にする（帯生成）
        //    → これが「帯」っぽさ（スライス）を作る
        let effectiveSlices = max(8, (numOverlays.intValue > 0 ? numOverlays.intValue : sliceCount.intValue))
        let horizontalBlurRadius = max(40.0, W / CGFloat(max(8, effectiveSlices / 2)))
        let motion = CIFilter.motionBlur()
        motion.inputImage = noise
        motion.radius = Float(horizontalBlurRadius)
        motion.angle = 0                           // 0rad = 水平ブラー
        let bandNoise = (motion.outputImage ?? noise).cropped(to: extent)

        // 3) アニメーション（timeでノイズを横に流す）
        let tx = CGAffineTransform(translationX: CGFloat(time.doubleValue * 40.0), y: 0)
        let animatedNoise = bandNoise.transformed(by: tx)

        // 4) 強さレンジ（minXSpan〜maxXSpan）を0.5中心に再マッピング
        //    CIDisplacementDistortion は 0.5 が中立。red=0.5±(振幅) となるよう調整する
        let baseScale = CGFloat((minXSpan.doubleValue + maxXSpan.doubleValue) * 3.0)
        let amplitude = max(0.05, min(0.49, baseScale / 10.0)) // 0.5±amplitude に収める

        // コントラスト強調で「薄い帯が多く・強い帯が少し」な分布に寄せる（p5のbiasの近似）
        let controls = CIFilter.colorControls()
        controls.inputImage = animatedNoise
        controls.contrast = Float(max(1.0, spanPowerX.doubleValue))
        let contrasted = (controls.outputImage ?? animatedNoise).cropped(to: extent)

        // 赤= 0.5 + (R-0.5)*amplitude、緑= 常に0.5（縦変位なし）
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = contrasted
        matrix.rVector = CIVector(x: amplitude, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0.5 - amplitude/2, y: 0.5, z: 0, w: 0)
        var displacement = matrix.outputImage!.cropped(to: extent)

        // 大スライス（低周波マスク）を加算的に重畳（近似）
        let lowFreqBlur = CIFilter.gaussianBlur()
        lowFreqBlur.inputImage = bandNoise
        lowFreqBlur.radius = Float(max(8.0, W / 6.0))
        let lowFreq = (lowFreqBlur.outputImage ?? bandNoise).cropped(to: extent)

        let bigMatrix = CIFilter.colorMatrix()
        bigMatrix.inputImage = lowFreq
        let bigAmp = min(0.49, amplitude * CGFloat(max(1.0, numBigSlices.doubleValue / 3.0)))
        bigMatrix.rVector = CIVector(x: bigAmp, y: 0, z: 0, w: 0)
        bigMatrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        bigMatrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        bigMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        bigMatrix.biasVector = CIVector(x: 0.5 - bigAmp/2, y: 0.5, z: 0, w: 0)
        let bigDisp = bigMatrix.outputImage!.cropped(to: extent)

        let add = CIFilter.additionCompositing()
        add.inputImage = displacement
        add.backgroundImage = bigDisp
        displacement = (add.outputImage ?? displacement).cropped(to: extent)

        // 右方向のみ（赤を0.5以上にクランプ）
        if biasRightOnly.intValue == 1 {
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = displacement
            clamp.minComponents = CIVector(x: 0.5, y: 0.5, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1.0, y: 0.5, z: 0, w: 1)
            displacement = clamp.outputImage!.cropped(to: extent)
        }

        // 5) 変位マップで入力画像を水平にずらす
        let disp = CIFilter.displacementDistortion()
        disp.inputImage = input
        disp.displacementImage = displacement
        disp.scale = 80.0                                   // 効果を視認しやすく強める
        let displaced = disp.outputImage?.cropped(to: extent) ?? input

        // 6) わずかな伸縮感：y方向に微弱なディストーション（ほぼわからない程度）
        //    Gチャンネルに小さなノイズを入れて再度軽く適用（好みに応じて0でもOK）
        // 縦変位は行わない（緑=0.5固定のため）
        return displaced
    }
}
