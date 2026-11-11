//
//  inf6SyllabusDetailView1.swift
//  inf6
//
//  Created by decopin on 2026/02/23.
//

import Foundation
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

import CoreText
import UniformTypeIdentifiers

import Security
import Dispatch

extension Inf6SyllabusDetailView {

    // MARK: - Generated explanation PDFs (G検定)

    @MainActor
    func _gkenteiGeneratedPDFDirectoryOrThrow() throws -> URL {
        // ここは「生成フォルダ」ではなく、ユーザーが選んだ「保存先フォルダ」です。
        let dir: URL
        do {
            if let u = gkenteiFolderURL {
                dir = u
            } else if let restored = try loadPersistedGkenteiExplanationPDFFolder() {
                gkenteiFolderURL = restored
                dir = restored
            } else {
                throw NSError(domain: "Inf6PDF", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text(
                        "保存先フォルダが未指定です。右側の『選択…』で保存先フォルダを指定してください。",
                        "Destination folder is not set. Please choose a folder first."
                    )
                ])
            }
        } catch {
            throw NSError(domain: "Inf6PDF", code: 40, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "PDF一覧を開けません。保存先フォルダが未設定、または解決に失敗しました: \(error)",
                    "Cannot open the PDF list. The destination folder is not set or failed to resolve: \(error)"
                )
            ])
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "Inf6PDF", code: 41, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "保存先フォルダが見つかりません（フォルダではありません）。\n\n保存先: \(dir.path)",
                    "Destination folder was not found (not a directory).\n\nPath: \(dir.path)"
                )
            ])
        }

        return dir
    }

    @MainActor
    func _reloadGkenteiGeneratedPDFListOrThrow() throws {
        let dir = try _gkenteiGeneratedPDFDirectoryOrThrow()
        // Always show which folder we are listing (this is the user's chosen save destination).
        gkenteiGeneratedPDFListStatus = Inf6Lang.text(
            "保存先: \(dir.path)",
            "Directory: \(dir.path)"
        )
        // User-chosen folder can be iCloud Drive; sandbox requires a security-scoped access.
        let didAccess = dir.startAccessingSecurityScopedResource()
        guard didAccess else {
            throw NSError(domain: "Inf6PDF", code: 257, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "PDF一覧を開けません（保存先フォルダへのアクセス権がありません）。右側の『選択…』で保存先フォルダを選び直してください。\n\n対象: \(dir.path)",
                    "Cannot open the PDF list (no permission to access the destination folder). Please choose the destination folder again.\n\nTarget: \(dir.path)"
                )
            ])
        }
        defer { dir.stopAccessingSecurityScopedResource() }
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let pdfs = urls.filter { u in
            u.isFileURL && u.pathExtension.localizedLowercase == "pdf"
        }

        func modDate(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }

        let sorted = pdfs.sorted { modDate($0) > modDate($1) }
        gkenteiGeneratedPDFItems = sorted

        if sorted.isEmpty {
            gkenteiGeneratedPDFListStatus = Inf6Lang.text(
                "PDFがありません。保存先フォルダにPDFを保存した後、右上の更新で再読み込みしてください。\n\n保存先: \(dir.path)",
                "No PDFs were found. After saving PDFs into this folder, tap refresh to reload.\n\nDirectory: \(dir.path)"
            )
        } else {
            gkenteiGeneratedPDFListStatus = Inf6Lang.text(
                "保存先: \(dir.path)\nPDF件数: \(sorted.count)",
                "Directory: \(dir.path)\nPDFs: \(sorted.count)"
            )
        }
    }

    @MainActor
    func openGkenteiGeneratedPDFList() {
        do {
            try _reloadGkenteiGeneratedPDFListOrThrow()
            showGkenteiGeneratedPDFListSheet = true
        } catch {
            let msg = Inf6Lang.text(
                "PDF一覧の読み込みに失敗しました: \(error)",
                "Failed to load PDFs: \(error)"
            )
            // Show the sheet with the message so it never appears blank.
            gkenteiGeneratedPDFItems = []
            gkenteiGeneratedPDFListStatus = msg
            showGkenteiGeneratedPDFListSheet = true

            explanationPDFStatus = msg
            explanationPDFErrorAlertMessage = msg
            showExplanationPDFErrorAlert = true
        }
    }

    @ViewBuilder
    var gkenteiGeneratedPDFListPanel: some View {
        List {
            if !gkenteiGeneratedPDFListStatus.isEmpty {
                Text(gkenteiGeneratedPDFListStatus)
                    .font(.caption)
                    .foregroundStyle(Color.blue)
            }

            ForEach(gkenteiGeneratedPDFItems, id: \.self) { u in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(u.lastPathComponent)
                            .font(.body)
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Text(u.path)
                            .font(.caption2)
                            .foregroundStyle(Color.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    Menu {
                        Button {
                            quickLookExplanationPDFURL = u
                        } label: {
                            Label(
                                Inf6Lang.text("プレビュー", "Preview"),
                                systemImage: "eye"
                            )
                        }

                        Button {
                            NotificationCenter.default.post(
                                name: .inf6OpenSavedPaperPDFInLibrary,
                                object: u
                            )
                            explanationPDFStatus = Inf6Lang.text(
                                "生成済み解説PDFをライブラリに取り込むよう要求しました。",
                                "Requested the Library to import the generated explanation PDF."
                            )
                        } label: {
                            Label(
                                Inf6Lang.text("ライブラリへ取り込む", "Import to Library"),
                                systemImage: "tray.and.arrow.down"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(20), weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .tint(Color.accentColor)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle(Inf6Lang.text("生成済みPDF", "Generated PDFs"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        openGkenteiGeneratedPDFList()
                    } label: {
                        Label(
                            Inf6Lang.text("保存先PDF一覧…", "Saved PDFs…"),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                } label: {
                    Label(
                        Inf6Lang.text("開く…", "Open…"),
                        systemImage: "tray.and.arrow.down"
                    )
                }
            }
        }
    }
}

#if canImport(WebKit)
@available(iOS 14.0, macOS 11.0, *)
final class _Inf6PDFNavDelegate: NSObject, WKNavigationDelegate {
    var cont: CheckedContinuation<Void, Error>?

    func waitFinished() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.cont = c
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        cont?.resume()
        cont = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        cont?.resume(throwing: error)
        cont = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        cont?.resume(throwing: error)
        cont = nil
    }
}
#endif
