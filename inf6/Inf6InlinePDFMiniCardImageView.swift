import PDFKit
import SwiftUI
import UIKit

extension InlinePDFPagesView {
    struct _Inf6MiniPDFCardImageView: View {
        let pdfData: Data
        let baseHeight: CGFloat
        @Binding var isPinchingMiniMathImage: Bool

        @State private var _img: UIImage? = nil
        @State private var _lastWidth: CGFloat = 0

        @State private var _committedScale: CGFloat = 1.0
        @GestureState private var _pinchScale: CGFloat = 1.0
        @State private var _committedOffset: CGSize = .zero
        @GestureState private var _dragOffset: CGSize = .zero

        private func _clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat {
            max(r.lowerBound, min(r.upperBound, v))
        }

        private func _add(_ a: CGSize, _ b: CGSize) -> CGSize {
            CGSize(width: a.width + b.width, height: a.height + b.height)
        }

        private func _renderIfNeeded(width: CGFloat) {
            let w = max(1, width)
            if abs(w - _lastWidth) < 2, _img != nil { return }
            _lastWidth = w

            guard !pdfData.isEmpty else {
                _img = nil
                return
            }
            guard let doc = PDFDocument(data: pdfData),
                  let page = doc.page(at: 0)
            else {
                _img = nil
                return
            }

            let scale = UIScreen.main.scale
            let targetW = max(1, w * scale * 1.6)

            let pageBounds = page.bounds(for: .mediaBox)
            let aspect = (pageBounds.height > 0) ? (pageBounds.height / pageBounds.width) : 1
            let targetSize = CGSize(width: targetW, height: max(1, targetW * aspect))

            _img = page.thumbnail(of: targetSize, for: .mediaBox)
        }

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let live = _clamp(_committedScale * _pinchScale, 1.0...4.0)
                let liveOffsetRaw = _add(_committedOffset, _dragOffset)

                ZStack {
                    if let img = _img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .modifier(_Inf6MiniImagePanZoomModifier(
                                scale: live,
                                rawOffset: liveOffsetRaw,
                                containerSize: geo.size,
                                image: img
                            ))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                MagnificationGesture(minimumScaleDelta: 0.03)
                                    .onChanged { _ in
                                        if !isPinchingMiniMathImage {
                                            DispatchQueue.main.async {
                                                isPinchingMiniMathImage = true
                                            }
                                        }
                                    }
                                    .updating($_pinchScale) { value, state, _ in
                                        state = value
                                    }
                                    .onEnded { value in
                                        _committedScale = _clamp(_committedScale * value, 1.0...4.0)
                                        if _committedScale <= 1.0001 {
                                            _committedScale = 1.0
                                            _committedOffset = .zero
                                        }
                                        DispatchQueue.main.async {
                                            isPinchingMiniMathImage = false
                                        }
                                    },
                                including: .all
                            )
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 2)
                                    .updating($_dragOffset) { value, state, _ in
                                        state = live > 1.0001 ? value.translation : .zero
                                    }
                                    .onEnded { value in
                                        if live > 1.0001 {
                                            _committedOffset = _add(_committedOffset, value.translation)
                                        } else {
                                            _committedOffset = .zero
                                        }
                                    },
                                including: .all
                            )
                            .onTapGesture(count: 2) {
                                _committedScale = 1.0
                                _committedOffset = .zero
                                DispatchQueue.main.async {
                                    isPinchingMiniMathImage = false
                                }
                            }
                    } else {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                    }
                }
                .onAppear {
                    _renderIfNeeded(width: w)
                }
                .onChange(of: w) { _, newW in
                    _renderIfNeeded(width: newW)
                }
            }
            .frame(height: baseHeight)
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private struct _Inf6MiniImagePanZoomModifier: ViewModifier {
        let scale: CGFloat
        let rawOffset: CGSize
        let containerSize: CGSize
        let image: UIImage

        func body(content: Content) -> some View {
            let asp: CGFloat = {
                guard image.size.width > 0 else { return 1 }
                return max(0.05, image.size.height / image.size.width)
            }()

            let cw = max(1, containerSize.width)
            let ch = max(1, containerSize.height)
            let fitWByH = ch / asp
            let baseW: CGFloat
            let baseH: CGFloat
            if fitWByH <= cw {
                baseW = fitWByH
                baseH = ch
            } else {
                baseW = cw
                baseH = cw * asp
            }

            let scaledW = baseW * scale
            let scaledH = baseH * scale
            let extraW = max(0, scaledW - cw)
            let extraH = max(0, scaledH - ch)

            let maxX = extraW * 0.5
            let maxY = extraH * 0.5

            let x = max(-maxX, min(maxX, rawOffset.width))
            let y = max(-maxY, min(maxY, rawOffset.height))

            return content
                .scaleEffect(scale, anchor: .center)
                .offset(x: x, y: y)
        }
    }
}
