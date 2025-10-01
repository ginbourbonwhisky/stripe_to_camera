import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraViewModel()
    @State private var showPreview = false
    @State private var blackout = false
    @State private var flashPreview: UIImage?
    @State private var showFiltered = true
    @State private var toggleTimer: Timer?
    @State private var filterNameHUD: String = "stripe001"
    @State private var dragAccumX: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if showFiltered, let frame = camera.filteredImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else if let raw = camera.originalImage {
                Image(uiImage: raw)
                    .resizable()
                    .scaledToFill()
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

            // フィルター名HUD
            Text(filterNameHUD)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35))
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .padding(.bottom, 8)

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
                    .overlay(Circle().fill(.white.opacity(0.2)).frame(width: 70, height: 70))
                    .padding(.bottom, 32)
            }
        }
        .onAppear {
            camera.start()
            toggleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFiltered.toggle()
                }
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
        // ダブルタップでstripe001/stripe002切替
        .onTapGesture(count: 2) {
            camera.useStripe001.toggle()
            filterNameHUD = camera.useStripe001 ? "stripe001" : "stripe002"
        }
        // 横スワイプで切替（左/右どちらでも閾値超でトグル）
        .gesture(
            DragGesture(minimumDistance: 16, coordinateSpace: .local)
                .onChanged { value in
                    dragAccumX += value.translation.width
                }
                .onEnded { _ in
                    let threshold: CGFloat = 60
                    if abs(dragAccumX) > threshold {
                        camera.useStripe001.toggle()
                        filterNameHUD = camera.useStripe001 ? "stripe001" : "stripe002"
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    }
                    dragAccumX = 0
                }
        )
    }
}

#Preview { ContentView() }
