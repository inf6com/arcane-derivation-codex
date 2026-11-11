import SwiftUI
import PDFKit
import UIKit

struct PaperCropEditorView: View {
    let language: InterfaceLanguage
    let rootPath: String
    let paper: PaperRecord
    let onSaved: (PaperCrop) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = 1
    @State private var pageCount = 0
    @State private var pageImage: UIImage?
    @State private var crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var dragStart: CGPoint?
    @State private var kind: CropKind = .figure
    @State private var title = ""
    @State private var message: String?
    @State private var showReadablePreview = false
    @State private var recognizedMathML: String?
    @State private var recognitionMessage: String?
    @State private var recognitionBusy = false

    private var isJapanese: Bool { language == .japanese }

    private func text(_ japanese: String, _ english: String) -> String {
        isJapanese ? japanese : english
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(paper.title).font(.headline).textSelection(.enabled)
                    if let pageImage {
                        Button(text("画像を拡大表示", "Enlarge page")) { showReadablePreview = true }
                            .buttonStyle(.bordered)
                        GeometryReader { proxy in
                            let frame = imageFrame(in: proxy.size)
                            ZStack {
                                Color.black.opacity(0.06)
                                Image(uiImage: pageImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: frame.width, height: frame.height)
                                    .position(x: frame.midX, y: frame.midY)
                                Rectangle()
                                    .stroke(.blue, lineWidth: 3)
                                    .frame(width: crop.width * frame.width, height: crop.height * frame.height)
                                    .position(x: frame.minX + crop.midX * frame.width,
                                              y: frame.minY + crop.midY * frame.height)
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let point = normalized(value.location, in: frame)
                                    if dragStart == nil { dragStart = point }
                                    guard let start = dragStart else { return }
                                    crop = normalizedRect(from: start, to: point)
                                }
                                .onEnded { _ in dragStart = nil })
                        }
                        .aspectRatio(pageImage.size.width / max(pageImage.size.height, 1), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if message == nil {
                        ProgressView(text("ページを読み込んでいます…", "Loading page…"))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    if pageCount > 0 {
                        HStack {
                            Button(text("前のページ", "Previous page")) { page = max(1, page - 1); loadPage() }
                                .disabled(page <= 1)
                            Text(text("ページ \(page) / \(pageCount)", "Page \(page) of \(pageCount)"))
                                .textSelection(.enabled)
                            Button(text("次のページ", "Next page")) { page = min(pageCount, page + 1); loadPage() }
                                .disabled(page >= pageCount)
                        }
                    }
                    Picker(text("種類", "Type"), selection: $kind) {
                        ForEach(CropKind.allCases, id: \.self) { Text(kindName($0)).tag($0) }
                    }
                    TextField(text("タイトル", "Title"), text: $title)
                        .textFieldStyle(.roundedBorder)
                    if kind == .equation {
                        Button(text("クロップした数式をMathMLへ変換", "Convert cropped equation to MathML")) { recognizeCrop() }
                            .buttonStyle(.borderedProminent)
                            .disabled(pageImage == nil || recognitionBusy)
                        if recognitionBusy { ProgressView() }
                        if let recognitionMessage { Text(recognitionMessage).font(.caption).textSelection(.enabled) }
                        if let recognizedMathML {
                            MathMLView(source: recognizedMathML)
                                .frame(height: 90)
                                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                    Button(text("クロップを保存", "Save crop")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(pageImage == nil
                                  || crop.isNull
                                  || crop.width <= 0
                                  || crop.height <= 0
                                  || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle(text("原典クロップ", "Source crop"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("閉じる", "Close")) { dismiss() }
                }
            }
            .onAppear { loadPage() }
            .navigationDestination(isPresented: $showReadablePreview) {
                if let pageImage {
                    ReadableImageView(image: pageImage)
                        .navigationTitle(text("原典画像", "Source page"))
                        .toolbarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView(
                        text("画像を表示できません", "Image unavailable"),
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    private var pdfURL: URL? {
        guard let relative = paper.pdfRelativePath, !relative.isEmpty else { return nil }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let url = root.appendingPathComponent(relative).standardizedFileURL
        return url.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func loadPage() {
        guard let pdfURL else {
            pageCount = 0
            pageImage = nil
            message = text("登録済みPDFが見つかりません。論文原典PDFを再登録してください。", "The registered PDF is missing. Register the source PDF again.")
            return
        }
        guard let document = PDFDocument(url: pdfURL) else {
            pageCount = 0
            pageImage = nil
            message = text("登録済みPDFを読み込めません。PDFを再登録してください。", "The registered PDF could not be opened. Register the PDF again.")
            return
        }
        guard document.pageCount > 0 else {
            pageCount = 0
            pageImage = nil
            message = text("登録済みPDFにページがありません。別のPDFを登録してください。", "The registered PDF has no pages. Register another PDF.")
            return
        }
        message = nil
        pageCount = document.pageCount
        page = min(max(page, 1), pageCount)
        guard let pdfPage = document.page(at: page - 1) else {
            pageImage = nil
            message = text("指定したページを読み込めません。PDFを再登録してください。", "The selected page could not be loaded. Register the PDF again.")
            return
        }
        let bounds = pdfPage.bounds(for: .mediaBox)
        pageImage = pdfPage.thumbnail(of: CGSize(width: 1600, height: 1600 * bounds.height / max(bounds.width, 1)), for: .mediaBox)
    }

    private func imageFrame(in size: CGSize) -> CGRect {
        guard let pageImage, pageImage.size.width > 0, pageImage.size.height > 0 else { return .zero }
        let scale = min(size.width / pageImage.size.width, size.height / pageImage.size.height)
        let imageSize = CGSize(width: pageImage.size.width * scale, height: pageImage.size.height * scale)
        return CGRect(x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - frame.minX) / max(frame.width, 1))),
                y: min(1, max(0, (point.y - frame.minY) / max(frame.height, 1))))
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func kindName(_ kind: CropKind) -> String {
        switch kind {
        case .figure: text("図", "Figure")
        case .table: text("表", "Table")
        case .equation: text("数式", "Equation")
        }
    }

    private func save() {
        do {
            guard let pdfURL else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: text(
                    "登録済みPDFが見つかりません。論文原典PDFを再登録してください。",
                    "The registered PDF is missing. Register the source PDF again."
                )])
            }
            let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
            let savedCrop = try PDFCropService(root: workspace).createCrop(paperID: paper.id, pdfURL: pdfURL, kind: kind, page: page, title: title, normalizedRect: crop)
            onSaved(savedCrop)
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func recognizeCrop() {
        guard let pageImage, let cgImage = pageImage.cgImage else {
            recognitionMessage = text("数式画像を読み込めません。", "The equation image could not be loaded.")
            return
        }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let rect = CGRect(x: crop.minX * imageWidth,
                          y: (1 - crop.maxY) * imageHeight,
                          width: crop.width * imageWidth,
                          height: crop.height * imageHeight).integral
        guard let cropped = cgImage.cropping(to: rect), let data = UIImage(cgImage: cropped).pngData() else {
            recognitionMessage = text("クロップ画像を生成できません。", "The cropped image could not be created.")
            return
        }
        recognitionBusy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TexTellerFormulaRecognition.recognize(imageData: data)
                }.value
                recognizedMathML = result.mathML
                recognitionMessage = result.decodedExpression
            } catch { recognitionMessage = error.localizedDescription }
            recognitionBusy = false
        }
    }
}
