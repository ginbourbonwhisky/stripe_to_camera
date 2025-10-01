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

        // 4) 強さレンジ（minXSpan〜maxXSpan）を近似スケーリング
        //    p5のバイアス（spanPowerX）を反映する代替として、コントラストとバイアスで分布を片寄らせる
        let spanAvg = CGFloat((minXSpan.doubleValue + maxXSpan.doubleValue) * 0.5)
        let baseScale = CGFloat((minXSpan.doubleValue + maxXSpan.doubleValue) * 6.0)

        // コントラスト強調で「薄い帯が多く・強い帯が少し」な分布に寄せる
        let controls = CIFilter.colorControls()
        controls.inputImage = animatedNoise
        controls.contrast = Float(max(1.0, spanPowerX.doubleValue))
        let contrasted = (controls.outputImage ?? animatedNoise).cropped(to: extent)

        // 赤ch＝横変位、緑=0（縦変位なし）
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = contrasted
        matrix.rVector = CIVector(x: baseScale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: -baseScale/2, y: 0, z: 0, w: 0)
        var displacement = matrix.outputImage!.cropped(to: extent)

        // 大スライス（低周波マスク）を加算的に重畳（近似）
        let lowFreqBlur = CIFilter.gaussianBlur()
        lowFreqBlur.inputImage = bandNoise
        lowFreqBlur.radius = Float(max(8.0, W / 6.0))
        let lowFreq = (lowFreqBlur.outputImage ?? bandNoise).cropped(to: extent)

        let bigMatrix = CIFilter.colorMatrix()
        bigMatrix.inputImage = lowFreq
        let bigScale = baseScale * CGFloat(max(1.0, numBigSlices.doubleValue / 3.0))
        bigMatrix.rVector = CIVector(x: bigScale, y: 0, z: 0, w: 0)
        bigMatrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        bigMatrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        bigMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        bigMatrix.biasVector = CIVector(x: -bigScale/2, y: 0, z: 0, w: 0)
        let bigDisp = bigMatrix.outputImage!.cropped(to: extent)

        let add = CIFilter.additionCompositing()
        add.inputImage = displacement
        add.backgroundImage = bigDisp
        displacement = (add.outputImage ?? displacement).cropped(to: extent)

        // 右方向のみ（負の変位をカット）
        if biasRightOnly.intValue == 1 {
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = displacement
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 0, z: 0, w: 1)
            displacement = clamp.outputImage!.cropped(to: extent)
        }

        // 5) 変位マップで入力画像を水平にずらす
        let disp = CIFilter.displacementDistortion()
        disp.inputImage = input
        disp.displacementImage = displacement
        disp.scale = 1.0                                   // 既にmatrixでスケール済み
        let displaced = disp.outputImage?.cropped(to: extent) ?? input

        // 6) わずかな伸縮感：y方向に微弱なディストーション（ほぼわからない程度）
        //    Gチャンネルに小さなノイズを入れて再度軽く適用（好みに応じて0でもOK）
        let tinyYNoise = (CIFilter.randomGenerator().outputImage!
            .cropped(to: extent))
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 4.0])

        let yMatrix = CIFilter.colorMatrix()
        yMatrix.inputImage = tinyYNoise
        yMatrix.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)                    // R=0（横なし）
        yMatrix.gVector = CIVector(x: 0, y: 0.02, z: 0, w: 0)                 // G=微小（縦±）
        yMatrix.biasVector = CIVector(x: 0, y: -0.01, z: 0, w: 0)

        let yDisplacement = yMatrix.outputImage!.cropped(to: extent)

        let disp2 = CIFilter.displacementDistortion()
        disp2.inputImage = displaced
        disp2.displacementImage = yDisplacement
        disp2.scale = 1.0

        return disp2.outputImage?.cropped(to: extent) ?? displaced
    }
}
