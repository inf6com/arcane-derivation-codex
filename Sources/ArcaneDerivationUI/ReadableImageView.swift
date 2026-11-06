import SwiftUI
import UIKit

struct ReadableImageView: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnificationGesture)
                    .simultaneousGesture(panGesture)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Button("全体") { reset() }
                    Button("原寸") {
                        scale = max(1, min(8, max(proxy.size.width / image.size.width, proxy.size.height / image.size.height)))
                        offset = .zero
                    }
                    Text("\(Int(scale * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .onAppear { reset() }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(1, min(8, baseScale * value.magnification))
            }
            .onEnded { _ in baseScale = scale }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func reset() {
        scale = 1
        offset = .zero
        baseScale = 1
        baseOffset = .zero
    }
}
