//
//  Inf6DrillStudyCard.swift
//  inf6
//
//  E資格 集中特訓の演習カード。
//
//  演習は「正しい内容を理解すること」が目的であり、選択式の出題形式を取らない。
//  そのため選択肢・正誤判定・答えの開閉を一切持たず、根拠とその正しい解説だけを提示する。
//  4択形式の QuizQuestionCard とは用途が異なるため、共用せず独立したビューとして実装する。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum Inf6EntityImageReadabilitySizer {
    private static let _pxPerPDFPoint: CGFloat = 2.0
    private static let _paperTextPointSize: CGFloat = 10.0
    private static let _initialSizeBoost: CGFloat = 1.2

    static func initialHeight(
        image: UIImage,
        bodyPointSize: CGFloat,
        entityImageMaxHeight: CGFloat,
        maxRenderableHeight: CGFloat,
        maxZoomScale: CGFloat
    ) -> CGFloat {
        _ = bodyPointSize
        guard image.size.width > 0, image.size.height > 0 else { return entityImageMaxHeight }
        let screenWidth = UIScreen.main.bounds.width
        let displayWidth = max(screenWidth - 64, 320)
        let baseHeight = displayWidth * image.size.height / image.size.width
        let aspectRatio = image.size.height / image.size.width
        let readableBaseMaxHeight = max(entityImageMaxHeight, 720)
        let aspectAdjustedMaxHeight = readableBaseMaxHeight
            * min(max(aspectRatio, 1), 2)
        return min(
            baseHeight,
            aspectAdjustedMaxHeight,
            maxRenderableHeight / maxZoomScale
        )
    }

    /// 画像内部の文字が本文と同程度に読める倍率を、画像の実ピクセル文字高から求める。
    /// 画像全体を無条件に拡大せず、文字が小さい画像だけを初期表示で拡大する。
    static func initialZoomScale(image: UIImage, bodyPointSize: CGFloat) -> CGFloat {
        // 横長の図は、文字可読性の自動倍率を適用すると表示枠から左右が
        // はみ出して図全体を確認できなくなる。初期表示は必ず全体表示とし、
        // 必要な拡大は利用者のズーム操作に委ねる。
        guard image.size.height > image.size.width else { return 1 }
        guard let glyphHeight = estimatedInternalGlyphHeight(image: image),
              glyphHeight > 0,
              let cgImage = image.cgImage,
              cgImage.width > 0 else { return 1 }

        let screenWidth = UIScreen.main.bounds.width
        let displayWidth = max(screenWidth - 64, 320)
        let projectedGlyphHeight = glyphHeight * displayWidth / CGFloat(cgImage.width)
        let targetGlyphHeight = max(12, bodyPointSize * 0.82)
        return min(max(targetGlyphHeight / projectedGlyphHeight, 1), 2.8)
    }

    static func internalTextReadabilityScale(image: UIImage, bodyPointSize: CGFloat) -> CGFloat {
        guard let glyphHeight = estimatedInternalGlyphHeight(image: image), glyphHeight > 0 else {
            return 1
        }
        let sourceWidth = CGFloat(image.cgImage?.width ?? 0)
        guard sourceWidth > 0 else { return 1 }
        let displayWidth = max(UIScreen.main.bounds.width - 64, 320)
        let projectedGlyphHeight = glyphHeight * displayWidth / sourceWidth
        let targetGlyphHeight = max(12, bodyPointSize * 0.82)
        return min(max(targetGlyphHeight / projectedGlyphHeight, 1), 2.8)
    }

    /// 図の外周にある白い余白だけを除去する。表示枠の高さを固定せず、
    /// 内容のアスペクト比を保ったままカード幅へ収めるために使う。
    static func trimOuterWhitespace(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0 else { return image }

        let maxSide = 1400
        let sampleScale = min(1.0, CGFloat(maxSide) / CGFloat(max(sourceWidth, sourceHeight)))
        let sampleWidth = max(1, Int((CGFloat(sourceWidth) * sampleScale).rounded()))
        let sampleHeight = max(1, Int((CGFloat(sourceHeight) * sampleScale).rounded()))
        var pixels = [UInt8](repeating: 255, count: sampleWidth * sampleHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        let threshold: UInt8 = 244
        var minX = sampleWidth
        var minY = sampleHeight
        var maxX = -1
        var maxY = -1
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth where pixels[y * sampleWidth + x] < threshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }

        let paddingX = max(2, Int(CGFloat(sampleWidth) * 0.02))
        let paddingY = max(2, Int(CGFloat(sampleHeight) * 0.02))
        let cropMinX = max(0, minX - paddingX)
        let cropMinY = max(0, minY - paddingY)
        let cropMaxX = min(sampleWidth - 1, maxX + paddingX)
        let cropMaxY = min(sampleHeight - 1, maxY + paddingY)
        let cropWidth = cropMaxX - cropMinX + 1
        let cropHeight = cropMaxY - cropMinY + 1

        // 微小な差や、背景色付き画像を誤って切らない。
        guard cropWidth < Int(CGFloat(sampleWidth) * 0.98)
                || cropHeight < Int(CGFloat(sampleHeight) * 0.98) else { return image }

        let scaleX = CGFloat(sourceWidth) / CGFloat(sampleWidth)
        let scaleY = CGFloat(sourceHeight) / CGFloat(sampleHeight)
        let rect = CGRect(
            x: CGFloat(cropMinX) * scaleX,
            y: CGFloat(cropMinY) * scaleY,
            width: CGFloat(cropWidth) * scaleX,
            height: CGFloat(cropHeight) * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func estimatedInternalGlyphHeight(image: UIImage) -> CGFloat? {
        guard let cgImage = image.cgImage else { return nil }
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let maxSide = 720
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var visited = [Bool](repeating: false, count: width * height)
        var heights: [CGFloat] = []
        heights.reserveCapacity(128)
        let bottomCaptionStart = Int(CGFloat(height) * 0.88)
        let darkThreshold: UInt8 = 170

        for y in 0..<bottomCaptionStart {
            for x in 0..<width {
                let start = y * width + x
                guard !visited[start], pixels[start] < darkThreshold else { continue }
                var queue = [Int]()
                queue.reserveCapacity(32)
                queue.append(start)
                visited[start] = true
                var head = 0
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var area = 0

                while head < queue.count {
                    let index = queue[head]
                    head += 1
                    area += 1
                    let cy = index / width
                    let cx = index - (cy * width)
                    minX = min(minX, cx)
                    maxX = max(maxX, cx)
                    minY = min(minY, cy)
                    maxY = max(maxY, cy)

                    for ny in max(0, cy - 1)...min(height - 1, cy + 1) {
                        for nx in max(0, cx - 1)...min(width - 1, cx + 1) {
                            let next = ny * width + nx
                            guard !visited[next], pixels[next] < darkThreshold else { continue }
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }

                let boxWidth = CGFloat(maxX - minX + 1) / scale
                let boxHeight = CGFloat(maxY - minY + 1) / scale
                let originalArea = CGFloat(area) / (scale * scale)
                guard boxHeight >= 4,
                      boxHeight <= 24,
                      boxWidth >= 1,
                      boxWidth <= 90,
                      originalArea >= 4,
                      originalArea <= 900,
                      boxWidth / max(boxHeight, 1) <= 9 else { continue }
                heights.append(boxHeight)
            }
        }

        guard heights.count >= 12 else { return nil }
        heights.sort()
        return heights[max(0, min(heights.count - 1, heights.count / 4))]
    }

}

struct Inf6CodePracticeExplanationView: View {
    private enum _Block: Identifiable {
        case text(String, Int)
        case code(String, Int)

        var id: Int {
            switch self {
            case .text(_, let id): return id
            case .code(_, let id): return id
            }
        }
    }

    let text: String
    let fontScale: CGFloat
    let tint: Color
    let textTint: Color
    var onSelectionChanged: ((String) -> Void)? = nil

    private var _safeFontScale: CGFloat {
        guard fontScale.isFinite else { return 1.0 }
        return min(max(fontScale, 0.85), 2.20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(_blocks(from: text)) { block in
                switch block {
                case .text(let value, _):
                    if !value.isEmpty {
                        _Inf6SelectableText(
                            text: value,
                            font: .systemFont(ofSize: 17 * _safeFontScale),
                            color: UIColor(textTint),
                            onSelectionChanged: onSelectionChanged
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let value, _):
                    _codeBlock(value)
                }
            }
        }
    }

    private func _blocks(from raw: String) -> [_Block] {
        let parts = raw.components(separatedBy: "```")
        guard parts.count >= 3 else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed, 0)]
        }
        var result: [_Block] = []
        for index in parts.indices {
            let trimmed = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if index.isMultiple(of: 2) {
                result.append(.text(trimmed, index))
            } else {
                result.append(.code(_stripLanguageLine(from: trimmed), index))
            }
        }
        return result
    }

    private func _stripLanguageLine(from raw: String) -> String {
        guard let newline = raw.firstIndex(of: "\n") else { return raw }
        let firstLine = raw[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstLine.isEmpty, !firstLine.contains(" ") else { return raw }
        return String(raw[raw.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _codeBlock(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(code.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                let isKeyLine = _isKeyCodeLine(line)
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16 * _safeFontScale), weight: isKeyLine ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(isKeyLine ? tint : textTint)
                    .padding(.horizontal, isKeyLine ? 6 : 0)
                    .padding(.vertical, isKeyLine ? 2 : 0)
                    .background(isKeyLine ? tint.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .textSelection(.enabled)
    }

    private func _isKeyCodeLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return [
            "nn.conv",
            "nn.linear",
            "nn.module",
            "dataloader",
            ".backward(",
            ".step(",
            ".train(",
            ".eval(",
            ".to(",
            "torch.no_grad",
            "tf.keras",
            "keras.layers",
            "gradienttape",
            "training="
        ].contains { lower.contains($0) }
    }
}

enum Inf6DrillExplainAction: String, CaseIterable, Identifiable {
    case deeper
    case terms
    case example
    case walkthrough

    var id: String { rawValue }

    func label(ja: Bool) -> String {
        switch self {
        case .deeper: return ja ? "さらに詳しく" : "In more depth"
        case .terms: return ja ? "用語をやさしく" : "Explain the terms"
        case .example: return ja ? "具体例で" : "With a concrete example"
        case .walkthrough: return ja ? "順を追って" : "Step by step"
        }
    }

    var systemImage: String {
        switch self {
        case .deeper: return "text.magnifyingglass"
        case .terms: return "character.book.closed"
        case .example: return "lightbulb"
        case .walkthrough: return "list.number"
        }
    }

    var instruction: String {
        switch self {
        case .deeper:
            return "この項目の内容を、より踏み込んで詳しく解説してください。"
        case .terms:
            return "この項目に出てくる専門用語を、初学者にも分かる言葉で説明してください。"
        case .example:
            return "この項目の内容を、具体例を挙げて説明してください。"
        case .walkthrough:
            return "この項目の内容を、順を追って段階的に説明してください。"
        }
    }
}

struct Inf6DrillStudyCard: View {

    /// 同じ根拠に紐づく理解ポイント。番号は画面全体の通し番号。
    struct Point: Identifiable {
        let number: Int
        let question: Inf6PaperQuizQuestion
        var id: UUID { question.id }
    }

    /// 先頭の要素から種別・ページ・画像を取る。画像付き項目はすべて同じエンティティである前提。
    let points: [Point]
    let langRaw: String

    private var q: Inf6PaperQuizQuestion { points[0].question }
    var fontScale: CGFloat = 1.0
    var entityImageMaxHeight: CGFloat = 200
    var tint: Color? = nil
    var textTint: Color? = nil
    var secondaryTextTint: Color? = nil
    var onImageTap: (() -> Void)? = nil

    /// Ask（追加解説）の記録。表示専用で、追加・削除は親ビューが行う。
    var askNotesFor: (UUID) -> [Inf6DrillAskNote] = { _ in [] }
    var onExplainDraft: ((UUID, InlinePDFPagesView._ExplainActionsDraft, String) -> Void)? = nil
    var onDeleteAskNote: ((UUID, UUID) -> Void)? = nil
    var isAsking: (UUID) -> Bool = { _ in false }
    var isLiveBPGenerated: Bool = false
    var onAddUnderstandingPoint: (() -> Void)? = nil
    var onDeleteEntityImage: (() -> Void)? = nil

    @State private var _imageZoomScale: CGFloat = 1
    @State private var _loadedImage: UIImage? = nil
    /// 読み込みに失敗したかどうか。待ち状態と区別しないと、失敗が永久のスピナーに見える。
    @State private var _imageLoadFailed = false
    @State private var _imageReloadToken = 0
    @State private var _askPanelQuestionID: UUID? = nil
    @State private var _selectedTextByQuestionID: [UUID: String] = [:]

    @inline(__always)
    private func L(_ ja: String, _ en: String) -> String {
        switch langRaw {
        case "ja": return ja
        case "en": return en
        default:
            let lang = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
            return lang.hasPrefix("ja") ? ja : en
        }
    }

    private var _safeFontScale: CGFloat {
        guard fontScale.isFinite else { return 1.0 }
        return min(max(fontScale, 0.85), 2.20)
    }

    private func _font(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: base * _safeFontScale, weight: weight)
    }

    private var _safeEntityImageMaxHeight: CGFloat {
        // 上限も従来(720)の1.5倍まで許容する。
        guard entityImageMaxHeight.isFinite else { return 300 }
        return min(max(entityImageMaxHeight, 300), 1080)
    }

    private var _textTint: Color { textTint ?? .primary }
    private var _secondaryTextTint: Color { secondaryTextTint ?? .secondary }

    private var _kindTint: Color {
        switch q.kind.lowercased() {
        case "figure": return .blue
        case "table": return .orange
        case "equation": return .purple
        case "code": return .green
        default: return tint ?? .accentColor
        }
    }

    private func _kindLabel(_ k: String) -> String {
        switch k.lowercased() {
        case "figure": return L("図", "Figure")
        case "table": return L("表", "Table")
        case "equation": return L("数式", "Equation")
        case "code": return L("Python", "Python")
        default: return k
        }
    }

    private func _loadEntityImageAsync() async -> UIImage? {
        guard let rel = q.entityImagePath else { return nil }
        // ローカル保存 root の実体だけを読む。
        guard let url = await Inf6EntityImageStore.ensureLocalFile(relativePath: rel) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let data = Inf6SafeFileRead.dataIfReadable(at: url) else { return nil as UIImage? }
            guard let image = UIImage(data: data) else { return nil as UIImage? }
            return Inf6EntityImageReadabilitySizer.trimOuterWhitespace(image)
        }.value
    }

    private func _initialImageHeight(_ image: UIImage) -> CGFloat {
        Inf6EntityImageReadabilitySizer.initialHeight(
            image: image,
            // UIフォント倍率は画像カードの大きさに影響させない。
            bodyPointSize: 17,
            entityImageMaxHeight: _safeEntityImageMaxHeight,
            maxRenderableHeight: Self._maxRenderableHeight,
            maxZoomScale: Self._maxZoomScale
        )
    }

    /// 拡大スライダーの上限。フレーム高さの計算と一致させる。
    static let _maxZoomScale: CGFloat = 8

    /// これを超える高さのビューは描画されず空白になるため、安全側に置く上限。
    private static let _maxRenderableHeight: CGFloat = 12000

    // MARK: - 画像縮尺の絶対契約
    //
    // 1. 初期倍率は画像内部の文字サイズを評価し、読める最小倍率を自動設定する。
    // 2. 画像は元画像のアスペクト比から初期高さを算出して表示する。
    // 3. 初期高さは画像のアスペクト比・内部文字サイズ・描画上限から決める。
    //    一律の固定高さや fontScale による画像倍率変更は行わない。
    // 4. 自動倍率は必要な場合だけ適用し、その後は利用者の操作で変更できる。
    // 5. trimOuterWhitespace は画像外周の余白除去だけを担当し、縮尺を決めない。
    //
    // この契約は、図・表・数式の表示を同じ規則で保つための変更禁止事項である。

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(spacing: 8) {
                Text(_kindLabel(q.kind))
                    .font(_font(12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(_kindTint.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(_kindTint)
                if let p = q.pageIndex {
                    Text(L("ページ \(p + 1)", "Page \(p + 1)"))
                        .font(_font(12))
                        .foregroundStyle(_secondaryTextTint)
                }
                if isLiveBPGenerated {
                    Label("AI", systemImage: "sparkles")
                        .font(_font(11, weight: .semibold))
                        .foregroundStyle(secondaryTextTint ?? tint ?? .blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.06))
                        .clipShape(Capsule())
                }
                Spacer()
                if q.entityImagePath != nil, let onDeleteEntityImage {
                    Button(action: onDeleteEntityImage) {
                        Image(systemName: "trash")
                            .font(_font(13, weight: .semibold))
                            .foregroundStyle(Color(uiColor: .systemBlue))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("この図表数式を削除", "Delete this visual evidence"))
                }
            }

            // 同じ図表数式は一度だけ出す。ポイントはその下にまとめて並べる。
            // 読み込み前に何も描かないと高さが確定せず、スクロール中に空白が出る。
            // 場所を確保したうえで読み込み中であることを示す。
            if let img = _loadedImage {
                _imageBlock(img)
            } else if q.entityImagePath != nil {
                if _imageLoadFailed {
                    _imageFailureBox
                } else {
                    _imagePlaceholder
                }
            }

            if let onAddUnderstandingPoint, q.question.isEmpty {
                Button(action: onAddUnderstandingPoint) {
                    Label(L("理解ポイントを追加", "Add understanding point"), systemImage: "sparkles")
                        .font(_font(15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(_kindTint)
            }

            ForEach(points) { point in
                _pointBlock(point)
            }
        }
        .padding(12)
        .textSelection(.enabled)
        .background(_kindTint.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(_kindTint.opacity(0.18), lineWidth: 1)
        }
        .task(id: "\(q.entityImagePath ?? "")#\(_imageReloadToken)") {
            guard _loadedImage == nil else { return }
            _imageLoadFailed = false
            let image = await _loadEntityImageAsync()
            guard !Task.isCancelled else { return }
            if let image {
                _loadedImage = image
                _imageZoomScale = Inf6EntityImageReadabilitySizer.initialZoomScale(
                    image: image,
                    bodyPointSize: 17
                )
            } else {
                // 読み込めなかったことを明示する。待ち続けさせない。
                _imageLoadFailed = true
            }
        }
    }



    /// 読み込みに失敗したときの表示。原因が分かるようにし、その場でやり直せるようにする。
    private var _imageFailureBox: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
            .frame(maxWidth: .infinity)
            .frame(height: 160 * _safeFontScale)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(L("\(_kindLabel(q.kind))の画像を読み込めませんでした",
                           "Could not load the \(_kindLabel(q.kind)) image"))
                        .font(_font(13))
                        .foregroundStyle(_secondaryTextTint)
                    Button(L("再読み込み", "Retry")) {
                        _imageLoadFailed = false
                        _imageReloadToken &+= 1
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
    }

    /// 図表数式の読み込み中に出す枠。高さを確保してレイアウトの揺れを防ぐ。
    private var _imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(_kindTint.opacity(0.05))
            .frame(maxWidth: .infinity)
            .frame(height: 320 * _safeFontScale)
            .overlay {
                VStack(spacing: 8) {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.large)
                    Text(L("\(_kindLabel(q.kind))を読み込み中", "Loading \(_kindLabel(q.kind))"))
                        .font(_font(13))
                        .foregroundStyle(_secondaryTextTint)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func _imageBlock(_ img: UIImage) -> some View {
        VStack(spacing: 8) {
            _Inf6PinchZoomImage(image: img, onTap: onImageTap, zoomScale: $_imageZoomScale)
                .frame(maxWidth: .infinity)
                .frame(height: _initialImageHeight(img))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            onImageTap != nil
                                ? (tint ?? .accentColor).opacity(0.5)
                                : Color.secondary.opacity(0.2),
                            lineWidth: onImageTap != nil ? 2 : 1
                        )
                }
            HStack(spacing: 10) {
                Button {
                    _imageZoomScale = max(1, _imageZoomScale - 0.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(_imageZoomScale <= 1)
                .accessibilityLabel(L("縮小", "Zoom out"))

                Slider(value: $_imageZoomScale, in: 1...Self._maxZoomScale, step: 0.1)
                    .accessibilityLabel(L("画像倍率", "Image zoom"))

                Button {
                    _imageZoomScale = min(Self._maxZoomScale, _imageZoomScale + 0.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(_imageZoomScale >= Self._maxZoomScale)
                .accessibilityLabel(L("拡大", "Zoom in"))

                Button("\(Int((_imageZoomScale * 100).rounded()))%") {
                    _imageZoomScale = 1
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L("倍率を100%に戻す", "Reset zoom to 100 percent"))
            }
        }
    }

    @ViewBuilder
    private func _askButton(questionID: UUID, asking: Bool) -> some View {
        Button {
            _askPanelQuestionID = questionID
        } label: {
            HStack(spacing: 6) {
                Image(systemName: asking ? "hourglass" : "sparkles")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                if !asking {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(9), weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.86))
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.96),
                                Color.cyan.opacity(0.84)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if asking {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.mini)
                        .tint(.white)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
            .shadow(color: Color.blue.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(asking)
        .popover(
            isPresented: Binding(
                get: { _askPanelQuestionID == questionID },
                set: { isPresented in
                    if !isPresented, _askPanelQuestionID == questionID {
                        _askPanelQuestionID = nil
                    }
                }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            if let point = points.first(where: { $0.question.id == questionID }),
               let onExplainDraft {
                InlinePDFPagesView._ExplainActionsPanelView(
                    pageIndex: max(point.number - 1, 0),
                    selectionText: _selectedTextByQuestionID[questionID] ?? point.question.question,
                    genLangRaw: langRaw,
                    isRunningExplain: asking,
                    onRun: { draft, selectionText, _ in
                        onExplainDraft(questionID, draft, selectionText)
                        _askPanelQuestionID = nil
                    },
                    onClose: { _askPanelQuestionID = nil }
                )
            }
        }
        .accessibilityLabel(L("解説を追加", "Add explanation"))
        .accessibilityHint(L("解説アクションを開きます", "Open explanation actions"))
        .help(L("対象と操作を選んで解説を実行", "Choose the target and action before running"))
    }

    @ViewBuilder
    private func _pointBlock(_ point: Inf6DrillStudyCard.Point) -> some View {
        let question = point.question
        let notes = askNotesFor(question.id)
        let asking = isAsking(question.id)

        if !question.question.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("ポイント\(point.number)", "Point \(point.number)"))
                    .font(_font(12, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(_kindTint.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(_kindTint)
                Spacer()
                if onExplainDraft != nil {
                    _askButton(questionID: question.id, asking: asking)
                }
            }

            // このアプリは iPad の作りのまま Mac で動く。SwiftUI の選択は
            // 長押しから始まるため、マウスでなぞるとスクロールになって
            // しまう。本文は UIKit の部品に任せ、ドラッグで選べるようにする。
            _Inf6SelectableText(
                text: question.question,
                font: .systemFont(ofSize: 17 * _safeFontScale, weight: .semibold),
                color: UIColor(_textTint),
                onSelectionChanged: { selected in
                    guard !selected.isEmpty else { return }
                    _selectedTextByQuestionID[question.id] = selected
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Inf6CodePracticeExplanationView(
                text: question.explanation,
                fontScale: _safeFontScale,
                tint: _kindTint,
                textTint: _textTint,
                onSelectionChanged: { selected in
                    guard !selected.isEmpty else { return }
                    _selectedTextByQuestionID[question.id] = selected
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(_kindTint.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    _Inf6SelectableText(
                        text: L("追加解説", "Additional explanations"),
                        font: .systemFont(ofSize: 12 * _safeFontScale, weight: .bold),
                        color: UIColor(_secondaryTextTint)
                    )

                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(_secondaryTextTint)
                                _Inf6SelectableText(
                                    text: note.prompt,
                                    font: .systemFont(ofSize: 15 * _safeFontScale, weight: .semibold),
                                    color: UIColor(_secondaryTextTint)
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let onDeleteAskNote {
                                    Button {
                                        onDeleteAskNote(question.id, note.id)
                                    } label: {
                                        Image(systemName: "trash").foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            _Inf6SelectableText(
                                text: note.answer,
                                font: .systemFont(ofSize: 16 * _safeFontScale),
                                color: UIColor(_textTint)
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .padding(.top, 2)
        }
    }
}
