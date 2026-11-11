import Foundation
import SwiftUI

extension InlinePDFPagesView {
    // MARK: - Ask note card

    var _askNoteSheetContent: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Askでメモカードを追加", "Add note card with Ask"))
                    .font(.headline)

                Text(L(
                    "返答はそのまま編集可能なメモカードとして追加されます。",
                    "The reply will be added as an editable note card."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

                TextEditor(text: $askNotePrompt)
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15)))
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary)
                    )

                if let msg = askNoteErrorMessage,
                   !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる", "Close")) {
                        isPresentingAskNoteSheet = false
                    }
                    .disabled(isAskingNote)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmed = askNotePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }

                        askNoteErrorMessage = nil
                        isAskingNote = true

                        Task { @MainActor in
                            defer { isAskingNote = false }
                            do {
                                let targetLang = (genLangRaw == "en") ? "en" : "ja"
                                let promptRef = (targetLang == "en")
                                    ? Inf6PromptCatalog.askNoteSheetEn
                                    : Inf6PromptCatalog.askNoteSheetJa
                                let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                                    ref: promptRef,
                                    variables: ["request_text": trimmed]
                                )
                                let result = try await Inf6LibraryView.askOpenAIText(
                                    systemInstruction: rendered.systemInstruction,
                                    userPrompt: rendered.userPrompt,
                                    lang: targetLang
                                )

                                let pageIndex = selectedPage.wrappedValue
                                withAnimation {
                                    var arr = extraNotesByPage[pageIndex] ?? _loadExtraNotesResolved(page: pageIndex)
                                    arr.append(Inf6ExtraNote(text: result))
                                    extraNotesByPage[pageIndex] = arr
                                    _persistExtraNotes(page: pageIndex, arr)
                                }

                                isPresentingAskNoteSheet = false
                            } catch {
                                askNoteErrorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        if isAskingNote {
                            ProgressView().tint(.pink).scaleEffect(1.25)
                        } else {
                            Text(L("生成して追加", "Generate & Add"))
                        }
                    }
                    .disabled(isAskingNote || askNotePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    var _askNoteMenuButton: some View {
        Menu {
            Button(L("Askでメモカードを追加", "Add note card (Ask)")) {
                let sel = _selectionTextUnified
                askNotePrompt = sel.isEmpty ? "" : sel
                askNoteErrorMessage = nil
                isPresentingAskNoteSheet = true
            }
        } label: {
            Label(L("メモ", "Note"), systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
                .foregroundStyle(.teal)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
        .accessibilityLabel(L("メモを追加", "Add note"))
        .accessibilityHint(L("メニューを開いて実行します", "Open menu to run"))
        .help(L("現在ページにメモカードを追加", "Add a note card to the current page"))
    }

    var _addExplanationFAB: some View {
        Button {
            withAnimation { showDetailPane = true }
            let idx = selectedPage.wrappedValue
            let sel = _selectionTextUnified
            if !sel.isEmpty {
                _requestExplain(pageIndex: idx, selectionText: sel)
            } else {
                _requestExplain(pageIndex: idx, selectionText: nil)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.bubble")
                Text("Add Explanation")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 1)
    }
}
