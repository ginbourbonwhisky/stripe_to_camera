import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraViewModel()
    @State private var showPreview = false
    @State private var blackout = false
    @State private var flashPreview: UIImage?

    var body: some View {
        ZStack {
            if let frame = camera.filteredImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                Spacer()
                Button {
                    // シャッター演出: ブラックアウト → 復帰 → 撮影フレームを一瞬表示
                    blackout = true
                    camera.captureStill()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        blackout = false
                        flashPreview = camera.capturedImage
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            flashPreview = nil
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
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
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
    }
}

#Preview { ContentView() }
