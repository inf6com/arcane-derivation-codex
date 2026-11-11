import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit

extension InlinePDFPagesView {
    struct Inf6RichTextNoteEditor: UIViewRepresentable {
        @Binding var note: Inf6ExtraNote
        let fontSize: CGFloat
        @Binding var selectionMirror: String
        @Binding var isInteracting: Bool
        @Binding var command: Inf6RichTextCommand?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UITextView {
            let tv = IntrinsicTextView()
            // Keep cards selectable without entering text-editing mode.
            tv.isEditable = false
            tv.isSelectable = true
            tv.isScrollEnabled = false
            tv.backgroundColor = .clear
            tv.textColor = .label
            tv.textContainerInset = .zero
            tv.textContainer.lineFragmentPadding = 0

            context.coordinator.isInternalUpdate = true
            tv.attributedText = InlinePDFPagesView._inf6AttributedFromNote(note, fontSize: fontSize)
            context.coordinator.isInternalUpdate = false

            tv.delegate = context.coordinator
            tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return tv
        }

        func updateUIView(_ tv: UITextView, context: Context) {
            tv.textColor = .label
            if tv.isEditable {
                tv.isEditable = false
            }

            let isUserInteracting = tv.isFirstResponder || context.coordinator.isSelectionLocked || isInteracting

            if !context.coordinator.isInternalUpdate {
                let incoming = InlinePDFPagesView._inf6AttributedFromNote(note, fontSize: fontSize)

                if !isUserInteracting {
                    if !(tv.attributedText?.isEqual(to: incoming) ?? false) {
                        let oldSel = tv.selectedRange
                        context.coordinator.isInternalUpdate = true
                        tv.attributedText = incoming
                        context.coordinator.isInternalUpdate = false
                        tv.selectedRange = oldSel
                        tv.invalidateIntrinsicContentSize()
                    } else {
                        tv.font = UIFont.systemFont(ofSize: max(10, fontSize))
                    }
                } else {
                    tv.font = UIFont.systemFont(ofSize: max(10, fontSize))
                }
            }

            if let cmd = command {
                context.coordinator.apply(cmd, to: tv)
                DispatchQueue.main.async {
                    self.command = nil
                }
            }
        }

        private final class IntrinsicTextView: UITextView {
            private var lastMeasuredWidth: CGFloat = 0

            lazy var inf6KeyboardAccessory: UIToolbar = {
                let bar = UIToolbar()
                bar.sizeToFit()

                let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
                let done = UIBarButtonItem(
                    title: Inf6Lang.text("閉じる", "Done"),
                    style: .done,
                    target: self,
                    action: #selector(_inf6DismissKeyboard)
                )
                bar.items = [spacer, done]
                return bar
            }()

            @objc private func _inf6DismissKeyboard() {
                resignFirstResponder()
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                let w = max(1, bounds.width)
                if abs(w - lastMeasuredWidth) > 0.5 {
                    lastMeasuredWidth = w
                    invalidateIntrinsicContentSize()
                }
            }

            override var intrinsicContentSize: CGSize {
                let w = max(1, bounds.width)
                let size = sizeThatFits(
                    CGSize(width: w, height: .greatestFiniteMagnitude)
                )
                return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
            }
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: Inf6RichTextNoteEditor
            var isInternalUpdate: Bool = false
            var lastRenderedText: String = ""
            var lastRenderedRTF: Data? = nil
            var lastRenderedFontSize: CGFloat = 0
            var _pendingSelectionMirrorWork: DispatchWorkItem? = nil
            var _lastMirroredSelection: String = ""
            var _pendingInteractionEndWork: DispatchWorkItem? = nil
            private var _selectionLockUntil: CFTimeInterval = 0
            var isSelectionLocked: Bool { CFAbsoluteTimeGetCurrent() < _selectionLockUntil }

            init(_ parent: Inf6RichTextNoteEditor) {
                self.parent = parent
            }

            private func commitNoteIfChanged(from textView: UITextView) {
                let attr = textView.attributedText ?? NSAttributedString(string: "")
                let newText = attr.string
                let newRTF = InlinePDFPagesView._inf6RTFData(from: attr)

                if parent.note.text != newText {
                    parent.note.text = newText
                }
                if parent.note.rtf != newRTF {
                    parent.note.rtf = newRTF
                }
            }

            func stripDefaultForegroundColorsIfNeeded(in textView: UITextView) {
                guard let attrText = textView.attributedText, attrText.length > 0 else { return }
                if isInternalUpdate { return }

                let full = NSRange(location: 0, length: attrText.length)
                let oldSel = textView.selectedRange

                isInternalUpdate = true
                textView.textStorage.beginEditing()
                textView.textStorage.enumerateAttribute(.foregroundColor, in: full, options: []) { v, r, _ in
                    guard let c = v as? UIColor else { return }
                    if InlinePDFPagesView._inf6IsDefaultForegroundUIColor(c) {
                        textView.textStorage.removeAttribute(.foregroundColor, range: r)
                    }
                }
                textView.textStorage.endEditing()
                textView.selectedRange = oldSel
                isInternalUpdate = false
            }

            func textViewDidChange(_ textView: UITextView) {
                guard !isInternalUpdate else { return }
                _selectionLockUntil = 0
                _pendingSelectionMirrorWork?.cancel()
                _pendingSelectionMirrorWork = nil
                _pendingInteractionEndWork?.cancel()
                _pendingInteractionEndWork = nil

                stripDefaultForegroundColorsIfNeeded(in: textView)

                let attr = textView.attributedText ?? NSAttributedString(string: "")
                let newText = attr.string
                let newRTF = InlinePDFPagesView._inf6RTFData(from: attr)

                if parent.note.text != newText {
                    parent.note.text = newText
                }
                if parent.note.rtf != newRTF {
                    parent.note.rtf = newRTF
                }

                DispatchQueue.main.async {
                    textView.invalidateIntrinsicContentSize()
                }

                if parent.isInteracting {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.parent.isInteracting {
                            self.parent.isInteracting = false
                        }
                    }
                }
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                if isInternalUpdate { return }

                func setInteracting(_ v: Bool) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.parent.isInteracting != v {
                            self.parent.isInteracting = v
                        }
                    }
                }

                func setSelectionMirror(_ v: String) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.parent.selectionMirror != v {
                            self.parent.selectionMirror = v
                        }
                    }
                }

                setInteracting(true)
                _selectionLockUntil = CFAbsoluteTimeGetCurrent() + 0.35
                _pendingSelectionMirrorWork?.cancel()
                _pendingSelectionMirrorWork = nil
                _pendingInteractionEndWork?.cancel()
                _pendingInteractionEndWork = nil

                let nsr = textView.selectedRange
                let next: String = {
                    guard nsr.length > 0,
                          let whole = textView.text,
                          let r = Range(nsr, in: whole)
                    else {
                        return ""
                    }
                    return String(whole[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                }()

                if next == _lastMirroredSelection {
                    let endWork = DispatchWorkItem { [weak self] in
                        guard self != nil else { return }
                        setInteracting(false)
                    }
                    _pendingInteractionEndWork = endWork
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: endWork)
                    return
                }

                // Publish non-empty text immediately. The AI action button can take focus
                // before the delayed mirror runs, which would otherwise lose the selection.
                if !next.isEmpty {
                    _lastMirroredSelection = next
                    setSelectionMirror(next)
                }

                let endWork = DispatchWorkItem { [weak self] in
                    guard self != nil else { return }
                    setInteracting(false)
                }
                _pendingInteractionEndWork = endWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: endWork)
            }

            func apply(_ cmd: Inf6RichTextCommand, to tv: UITextView) {
                _pendingSelectionMirrorWork?.cancel()
                _pendingSelectionMirrorWork = nil
                _pendingInteractionEndWork?.cancel()
                _pendingInteractionEndWork = nil
                isInternalUpdate = true
                defer {
                    isInternalUpdate = false

                    DispatchQueue.main.async { [weak self, weak tv] in
                        guard let self, let tv else { return }
                        guard tv.window != nil else { return }

                        self.commitNoteIfChanged(from: tv)
                        tv.invalidateIntrinsicContentSize()
                    }
                }

                let range = tv.selectedRange
                guard range.location != NSNotFound else { return }

                switch cmd {
                case .deleteSelection:
                    if range.length > 0 {
                        tv.textStorage.replaceCharacters(in: range, with: "")
                        tv.selectedRange = NSRange(location: range.location, length: 0)
                    }

                case .setHighlight(let h):
                    guard range.length > 0 else { return }
                    if let h {
                        let c = InlinePDFPagesView._inf6UIHighlightColor(h) as! UIColor
                        tv.textStorage.addAttribute(.backgroundColor, value: c, range: range)
                    } else {
                        tv.textStorage.removeAttribute(.backgroundColor, range: range)
                    }

                case .toggleUnderline:
                    guard range.length > 0 else { return }
                    let current = tv.textStorage.attribute(
                        .underlineStyle,
                        at: range.location,
                        effectiveRange: nil
                    ) as? NSNumber
                    let isOn = (current?.intValue ?? 0) != 0
                    if isOn {
                        tv.textStorage.removeAttribute(.underlineStyle, range: range)
                    } else {
                        tv.textStorage.addAttribute(
                            .underlineStyle,
                            value: NSUnderlineStyle.single.rawValue,
                            range: range
                        )
                    }

                case .setTextColor(let c):
                    guard range.length > 0 else { return }
                    if let c {
                        let col = InlinePDFPagesView._inf6UITextColor(c) as! UIColor
                        tv.textStorage.addAttribute(.foregroundColor, value: col, range: range)
                    } else {
                        tv.textStorage.removeAttribute(.foregroundColor, range: range)
                    }
                }
            }
        }
    }
}
#endif
