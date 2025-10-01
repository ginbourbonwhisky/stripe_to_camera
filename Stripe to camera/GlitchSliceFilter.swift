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

    private let context = CIContext(options: nil)

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        let extent = input.extent
        let W = extent.width
        let H = extent.height

        // 1) ノイズ生成
        let noise = CIFilter.randomGenerator().outputImage!
            .cropped(to: extent)

        // 2) ノイズを横方向に強くにじませ、各行でほぼ一定の値にする
        //    → これが「帯」っぽさ（スライス）を作る
        let horizontalBlurRadius = max(40.0, W / CGFloat(max(8, sliceCount.intValue / 2)))
        let motion = CIFilter.motionBlur()
        motion.inputImage = noise
        motion.radius = Float(horizontalBlurRadius)
        motion.angle = 0                           // 0rad = 水平ブラー
        let bandNoise = (motion.outputImage ?? noise).cropped(to: extent)

        // 3) アニメーション（timeでノイズを横に流す）
        let tx = CGAffineTransform(translationX: CGFloat(time.doubleValue * 40.0), y: 0)
        let animatedNoise = bandNoise.transformed(by: tx)

        // 4) 強さのレンジを指定（minXSpan〜maxXSpan を 0〜1 に正規化してスケーリング）
        //    → 赤chのみ残して緑=0（縦の変位は無し）
        let scale = CGFloat((minXSpan.doubleValue + maxXSpan.doubleValue) * 6.0) // 見た目係数
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = animatedNoise
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)     // R=スケール済
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)         // G=0（縦変位なし）
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: -scale/2, y: 0, z: 0, w: 0) // 正負に振る

        let displacement = matrix.outputImage!.cropped(to: extent)

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
