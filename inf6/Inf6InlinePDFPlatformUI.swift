import PDFKit
import SwiftUI
import UIKit

extension InlinePDFPagesView {
    var _platformSystemBackground: Color {
        Color(UIColor.systemBackground)
    }

    #if os(iOS)
    var _isDesignedForiPadOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.userInterfaceIdiom == .mac
    }
    #endif

    func _findFirstScrollView(in root: UIView) -> UIScrollView? {
        if let sv = root as? UIScrollView { return sv }
        for sub in root.subviews {
            if let found = _findFirstScrollView(in: sub) { return found }
        }
        return nil
    }

    @MainActor
    func _enableAndFlashPDFScrollIndicators(_ pdfView: PDFView) {
        guard let sv = _findFirstScrollView(in: pdfView) else {
            print("[InlinePDFPagesView] PDFView internal UIScrollView not found; cannot enable scroll indicators.")
            return
        }
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            sv.contentInsetAdjustmentBehavior = .never
            sv.contentInset = .zero
            sv.scrollIndicatorInsets = .zero
        }
        #endif
        sv.showsHorizontalScrollIndicator = true
        sv.showsVerticalScrollIndicator = true
        sv.flashScrollIndicators()
    }
}
