//
//  Inf6ThumbSizedSlider.swift
//  inf6
//
//  Created by Codex on 2026/05/27.
//

import SwiftUI
import UIKit

extension InlinePDFPagesView {
    struct Inf6ThumbSizedSlider: UIViewRepresentable {
        @Binding var value: CGFloat
        let range: ClosedRange<CGFloat>
        let step: CGFloat
        let thumbDiameter: CGFloat

        final class Coordinator: NSObject {
            var parent: Inf6ThumbSizedSlider

            init(_ parent: Inf6ThumbSizedSlider) {
                self.parent = parent
            }

            @objc func valueChanged(_ sender: UISlider) {
                let minV = Float(parent.range.lowerBound)
                let maxV = Float(parent.range.upperBound)
                let raw = max(minV, min(maxV, sender.value))

                let step = max(0.0001 as Float, Float(parent.step))
                let snapped = round((raw - minV) / step) * step + minV
                let clamped = max(minV, min(maxV, snapped))

                if sender.value != clamped {
                    sender.value = clamped
                }

                let newVal = CGFloat(clamped)
                if parent.value != newVal {
                    parent.value = newVal
                }
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UISlider {
            let slider = UISlider(frame: .zero)
            let minV = Float(range.lowerBound)
            let maxV = Float(range.upperBound)
            slider.minimumValue = minV
            slider.maximumValue = maxV
            slider.isContinuous = true

            let raw0: Float = value.isFinite ? Float(value) : Float(range.lowerBound)
            let initial = max(minV, min(maxV, raw0))
            slider.value = initial

            let img = Self._thumbImage(diameter: thumbDiameter)
            slider.setThumbImage(img, for: .normal)
            slider.setThumbImage(img, for: .highlighted)
            slider.minimumTrackTintColor = UIColor.systemBlue.withAlphaComponent(0.40)
            slider.maximumTrackTintColor = UIColor.systemBlue.withAlphaComponent(0.16)

            slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
            return slider
        }

        func updateUIView(_ uiView: UISlider, context: Context) {
            context.coordinator.parent = self

            uiView.minimumValue = Float(range.lowerBound)
            uiView.maximumValue = Float(range.upperBound)
            uiView.minimumTrackTintColor = UIColor.systemBlue.withAlphaComponent(0.40)
            uiView.maximumTrackTintColor = UIColor.systemBlue.withAlphaComponent(0.16)

            let incoming = value.isFinite ? value : range.lowerBound
            let clamped = max(range.lowerBound, min(range.upperBound, incoming))
            let current = CGFloat(uiView.value)
            if abs(current - clamped) > 0.0001 {
                uiView.value = Float(clamped)
            }

            let img = Self._thumbImage(diameter: thumbDiameter)
            uiView.setThumbImage(img, for: .normal)
            uiView.setThumbImage(img, for: .highlighted)
        }

        static func _thumbImage(diameter: CGFloat) -> UIImage {
            let ballD = max(6, diameter)
            let hitD: CGFloat = max(ballD, 28)
            let size = CGSize(width: hitD, height: hitD)

            let format = UIGraphicsImageRendererFormat()
            format.scale = UIScreen.main.scale
            format.opaque = false

            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.image { ctx in
                let origin = CGPoint(x: (hitD - ballD) * 0.5, y: (hitD - ballD) * 0.5)
                let rect = CGRect(origin: origin, size: CGSize(width: ballD, height: ballD))

                let fill = UIColor.systemBlue.withAlphaComponent(0.55)
                let stroke = UIColor.white.withAlphaComponent(0.35)

                ctx.cgContext.setFillColor(fill.cgColor)
                ctx.cgContext.fillEllipse(in: rect)

                ctx.cgContext.setStrokeColor(stroke.cgColor)
                ctx.cgContext.setLineWidth(1)
                ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }
}
