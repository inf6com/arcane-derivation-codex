import Foundation
import SwiftUI
import UIKit

extension InlinePDFPagesView {
    func _inf6ClampFinite(_ v: CGFloat, _ r: ClosedRange<CGFloat>, fallback: CGFloat, label: String) -> CGFloat {
        guard v.isFinite else {
            let msg = "[InlinePDFPagesView] non-finite \(label): \(v) -> \(fallback)"
            print(msg)
            _ioLastError = msg
            return fallback
        }
        return max(r.lowerBound, min(r.upperBound, v))
    }

    func _inf6SafeZoomForLayout(_ v: CGFloat) -> CGFloat {
        _inf6ClampFinite(v, 0.5...5.0, fallback: 1.0, label: "zoom")
    }

    func _inf6SafeDetailFontScaleForLayout(_ v: CGFloat) -> CGFloat {
        _inf6ClampFinite(v, 0.65...2.55, fallback: 1.0, label: "detailFontScalePDF")
    }

    // MARK: - HUDs

    var _zoomHUD: some View {
        #if os(iOS)
        let idiom = UIDevice.current.userInterfaceIdiom
        let isPhoneUI: Bool = (idiom == .phone)
        let isDesignedForiPadOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac || (idiom == .mac)
        let isPadDevice: Bool = (idiom == .pad) && !isDesignedForiPadOnMac
        #else
        let isPhoneUI: Bool = false
        let isDesignedForiPadOnMac: Bool = false
        let isPadDevice: Bool = true
        #endif

        let thumbD: CGFloat = {
            if isPhoneUI { return 10 }
            if isDesignedForiPadOnMac { return 16 }
            if isPadDevice { return 14 }
            return 14
        }()

        let sliderW: CGFloat = {
            if isPhoneUI { return 120 }
            if isDesignedForiPadOnMac { return 180 }
            if isPadDevice { return 160 }
            return 160
        }()

        let zoomBinding = Binding<CGFloat>(
            get: { _inf6SafeZoomForLayout(zoom) },
            set: { zoom = _inf6SafeZoomForLayout($0) }
        )

        let applyInitialPhoneZoomIfNeeded: () -> Void = {
            #if os(iOS)
            guard isPhoneUI else { return }
            guard !isDesignedForiPadOnMac else { return }
            let z = _inf6SafeZoomForLayout(zoom)
            if abs(Double(z) - 1.0) < 0.000001 {
                zoom = 0.88
            }
            #endif
        }

        return HStack(spacing: 2) {
            Inf6ThumbSizedSlider(
                value: zoomBinding,
                range: 0.5...5.0,
                step: 0.05,
                thumbDiameter: thumbD
            )
            .frame(width: sliderW)

            Text("\(Int((_inf6SafeZoomForLayout(zoom) * 100).rounded()))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color.blue.opacity(0.72))
        }
        .onAppear {
            applyInitialPhoneZoomIfNeeded()
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .foregroundStyle(Color.cyan.opacity(0.10))
        }
        .shadow(radius: 1)
        .padding(8)
    }

    var _detailFontHUD: some View {
        #if os(iOS)
        let idiom = UIDevice.current.userInterfaceIdiom
        let isPhoneUI: Bool = (idiom == .phone)
        let isDesignedForiPadOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac || (idiom == .mac)
        let isPadDevice: Bool = (idiom == .pad) && !isDesignedForiPadOnMac
        #else
        let isPhoneUI: Bool = false
        let isDesignedForiPadOnMac: Bool = false
        let isPadDevice: Bool = true
        #endif

        let iconFont: Font = {
            if isPhoneUI { return .caption2 }
            if isDesignedForiPadOnMac { return .body }
            if isPadDevice { return .body }
            return .body
        }()

        let iconScale: Image.Scale = {
            if isPhoneUI { return .small }
            if isDesignedForiPadOnMac { return .medium }
            if isPadDevice { return .medium }
            return .medium
        }()

        let thumbD: CGFloat = {
            if isPhoneUI { return 10 }
            if isDesignedForiPadOnMac { return 16 }
            if isPadDevice { return 14 }
            return 14
        }()

        let sliderW: CGFloat = {
            if isPhoneUI { return 120 }
            if isDesignedForiPadOnMac { return 220 }
            if isPadDevice { return 180 }
            return 180
        }()

        let scaleBinding = Binding<CGFloat>(
            get: { _inf6SafeDetailFontScaleForLayout(detailFontScalePDF) },
            set: { detailFontScalePDF = _inf6SafeDetailFontScaleForLayout($0) }
        )

        let applyInitialFontScaleIfNeeded: () -> Void = {
            #if os(iOS)
            guard !isDesignedForiPadOnMac else { return }

            let s = _inf6SafeDetailFontScaleForLayout(detailFontScalePDF)
            let isUntouchedDefaultish = (abs(Double(s) - 1.0) < 0.000001) || (abs(Double(s) - 1.8) < 0.000001)
            if isUntouchedDefaultish {
                if isPhoneUI {
                    detailFontScalePDF = 0.80
                } else if isPadDevice {
                    detailFontScalePDF = 0.95
                }
            }
            #endif
        }

        return HStack(spacing: 2) {
            Image(systemName: "textformat.size.smaller")
                .font(iconFont)
                .imageScale(iconScale)
                .foregroundStyle(Color.blue.opacity(0.55))

            Inf6ThumbSizedSlider(
                value: scaleBinding,
                range: 0.65...2.55,
                step: 0.05,
                thumbDiameter: thumbD
            )
            .frame(width: sliderW)
            .tint(Color.blue.opacity(0.55))

            Image(systemName: "textformat.size.larger")
                .font(iconFont)
                .imageScale(iconScale)
                .foregroundStyle(Color.blue.opacity(0.55))
        }
        .onAppear {
            applyInitialFontScaleIfNeeded()
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .foregroundStyle(Color.cyan.opacity(0.10))
        }
        .shadow(radius: 1)
    }
}
