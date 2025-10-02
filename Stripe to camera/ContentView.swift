import SwiftUI

// 円周に沿ってテキストを表示するカスタムビュー
struct CircularText: View {
    let text: String
    let radius: CGFloat
    let fontSize: CGFloat
    
    init(text: String, radius: CGFloat, fontSize: CGFloat = 10) {
        self.text = text
        self.radius = radius
        self.fontSize = fontSize
    }
    
    var body: some View {
        ZStack {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(.white)
                    .offset(y: -radius) // 円の外側に配置
                    .rotationEffect(.degrees(characterAngle(for: index)))
            }
        }
    }
    
    // テキストの中心が上部に来るように角度を計算
    private func characterAngle(for index: Int) -> Double {
        let totalCharacters = Double(text.count)
        let anglePerCharacter = 120.0 / totalCharacters // 120度範囲に配置
        let startAngle = 0.0 // 真上（0度）を中心とする
        let offsetAngle = anglePerCharacter * (Double(index) - (totalCharacters - 1) / 2.0)
        return startAngle + offsetAngle
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraViewModel()
    @State private var showPreview = false
    @State private var blackout = false
    @State private var flashPreview: UIImage?
    @State private var showFiltered = true
    @State private var toggleTimer: Timer?
    @State private var filterNameHUD: String = "stripe001"
    @State private var currentFilterIndex: Int = 0
    @State private var dragAccumX: CGFloat = 0

    var body: some View {
            ZStack(alignment: .bottom) {
                // フィルター表示ロジック
                if (currentFilterIndex == 1 || currentFilterIndex == 2), let frame = camera.filteredImage {
                    // stripe002, stripe003は常にフィルター画像を表示
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .ignoresSafeArea()
                } else if currentFilterIndex == 0 && showFiltered, let frame = camera.filteredImage {
                    // stripe001はトグル表示
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .ignoresSafeArea()
                } else if let raw = camera.originalImage {
                    Image(uiImage: raw)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

            // ブラックアウト演出
            Color.black
                .opacity(blackout ? 1.0 : 0.0)
                .ignoresSafeArea()

            // 一瞬のプレビュー
            if let shot = flashPreview {
                Image(uiImage: shot)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.55)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 10)
                    .padding(.bottom, 120)
                    .transition(.opacity)
            }

                // 撮影ボタン
                Button {
                    // シャッター演出: ブラックアウト → 復帰 → 撮影フレームを一瞬表示
                    blackout = true
                    camera.captureStill()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        blackout = false
                        flashPreview = camera.capturedImage
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                flashPreview = nil
                            }
                        }
                    }
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 6)
                        .frame(width: 82, height: 82)
                        .overlay(
                            ZStack {
                                Circle().fill(.white.opacity(0.2)).frame(width: 70, height: 70)
                                // フィルター名を円の外側に表示
                                CircularText(text: filterNameHUD, radius: 50, fontSize: 9)
                            }
                        )
                        .padding(.bottom, 32)
                }
        }
        .onAppear {
            camera.start()
            // stripe001の場合のみ1秒トグルを有効化
            if currentFilterIndex == 0 {
                startToggleTimer()
            }
        }
        .onDisappear {
            camera.stop()
            toggleTimer?.invalidate()
            toggleTimer = nil
        }
        .overlay {
            // ブラックアウト層
            if blackout {
                Color.black.ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .center) {
            // 一瞬の撮影プレビュー（中心にフェード）
            if let flash = flashPreview {
                Image(uiImage: flash)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.55)
                    .shadow(radius: 10)
                    .transition(.opacity)
            }
        }
        // 横スワイプで3つのフィルター間を切替
        .gesture(
            DragGesture(minimumDistance: 60, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width > 0 {
                        // 右スワイプ：前のフィルターへ
                        currentFilterIndex = (currentFilterIndex - 1 + 3) % 3
                    } else {
                        // 左スワイプ：次のフィルターへ
                        currentFilterIndex = (currentFilterIndex + 1) % 3
                    }
                    updateFilterSelection()
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                }
        )
    }
    
    private func startToggleTimer() {
        toggleTimer?.invalidate()
        toggleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showFiltered.toggle()
            }
        }
    }
    
    private func updateFilterSelection() {
        camera.currentFilterIndex = currentFilterIndex
        let filterNames = ["stripe001", "stripe002", "stripe003"]
        filterNameHUD = filterNames[currentFilterIndex]
        
        // stripe001の場合のみ1秒トグルを有効化
        if currentFilterIndex == 0 {
            startToggleTimer()
        } else {
            toggleTimer?.invalidate()
            toggleTimer = nil
            showFiltered = true // 他のフィルターは常にフィルター表示
        }
    }
}

#Preview { ContentView() }
