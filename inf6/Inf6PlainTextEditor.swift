//
//  Inf6PlainTextEditor.swift
//  inf6
//
//  Created by Codex on 2026/05/27.
//

import SwiftUI
import UIKit

struct Inf6PlainTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = true
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.textColor = .label
        tv.font = UIFont.systemFont(ofSize: Inf6ApplicationSystemFont.scaledSize(14))
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        tv.textContainer.lineFragmentPadding = 0

        tv.textContentType = .none
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no

        let bar = UIToolbar()
        bar.sizeToFit()
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(
            title: Inf6Lang.text("閉じる", "Done"),
            style: .done,
            target: tv,
            action: #selector(UIResponder.resignFirstResponder)
        )
        bar.items = [spacer, done]
        tv.inputAccessoryView = bar

        context.coordinator.isInternalUpdate = true
        tv.text = text
        context.coordinator.isInternalUpdate = false

        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        tv.font = UIFont.systemFont(ofSize: Inf6ApplicationSystemFont.scaledSize(14))

        if tv.markedTextRange != nil {
            return
        }

        if !context.coordinator.isInternalUpdate {
            let incoming = text
            if tv.text != incoming {
                context.coordinator.isInternalUpdate = true
                tv.text = incoming
                context.coordinator.isInternalUpdate = false
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: Inf6PlainTextEditor
        var isInternalUpdate: Bool = false
        private var pendingCommitWork: DispatchWorkItem? = nil

        init(_ parent: Inf6PlainTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isInternalUpdate else { return }
            pendingCommitWork?.cancel()

            if textView.markedTextRange != nil {
                return
            }

            let next = textView.text ?? ""
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.parent.text != next {
                    self.parent.text = next
                }
            }
            pendingCommitWork = work
            DispatchQueue.main.async(execute: work)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            pendingCommitWork?.cancel()
            let next = textView.text ?? ""
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.parent.text != next {
                    self.parent.text = next
                }
            }
            pendingCommitWork = work
            DispatchQueue.main.async(execute: work)
        }
    }
}
