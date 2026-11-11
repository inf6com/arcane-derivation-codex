//
//  Inf6DataExchange.swift
//  inf6
//
//  端末間でデータを持ち運ぶための書き出しと取り込み。
//

import Foundation
import Compression

extension Notification.Name {
    static let inf6DataExchangeDidImport = Notification.Name("inf6DataExchangeDidImport")
}

/// 生成したものを zip にまとめ、別の端末へ持ち運ぶ。
///
/// 同期には頼らない。置き場所も取り込み元も、その都度利用者が選ぶ。iCloud に
/// 置いても、外付けに置いても、AirDrop で送っても扱いは同じである。届いたか
/// どうかを推測せず、利用者が見て決められる形にする。
///
/// zip にするのは、iCloud に個々のファイルを触らせないためである。数千の小さな
/// ファイルは追い出しの対象になり、読むたびに取得を待たされる。zip なら iCloud
/// から見て1つのファイルで、中身に手を出せない。
///
/// 分ける単位は分野とノードにする。バイト数で機械的に切ると、ひとつのノードの
/// 図が2組にまたがり、片方だけ届いても使えない。学ぶ側から見て意味のある
/// かたまりで切れば、届いた組はそれだけで成立する。名前も分野とノードにする。
/// 何が入っているかが一覧で分かる。
///
/// ノードは小さいので、目安の大きさに達するまで詰めてから次の組に移る。
public enum Inf6DataExchange {

    public enum HistoryOperation: String, Codable {
        case export
        case `import`
    }

    public struct HistoryEntry: Codable, Identifiable {
        public var id: UUID
        public var operation: HistoryOperation
        public var happenedAt: String
        public var destinationPath: String?
        public var archiveNames: [String]
        public var archiveCount: Int
        public var fileCount: Int
    }

    /// ひとつの zip の目安の大きさ。
    ///
    /// 全部を固めると、途中で止まったときに何も使えない。細かく分けると数が
    /// 増え、iCloud に触らせたくないという狙いから外れる。ノードを詰めていき、
    /// この大きさを超えたところで次の組に移る。ノード単体がこれを超える場合は
    /// 分割せず、そのまま単独の組にする。
    private static let _targetPartBytes: Int64 = 200 * 1024 * 1024

    /// 書き出しの中身を記した目録。
    public struct Manifest: Codable {
        public var version: Int
        public var device: String
        public var createdAt: String
        /// zip の名前を、書き出した順に並べたもの。
        public var parts: [String]
        public var fileCount: Int
    }

    public struct ExportSummary {
        public let directory: URL
        public let partCount: Int
        public let fileCount: Int
        fileprivate let archiveNames: [String]
        fileprivate let ledgerUpdates: [String: TimeInterval]

        public var exportedFileURLs: [URL] {
            [directory.appendingPathComponent(Inf6DataExchange._manifestName)]
                + archiveNames.map { directory.appendingPathComponent($0) }
        }
    }

    private static let _manifestName = "manifest.json"
    private static let _historyKey = "data_exchange_history"
    private static let _revisionKey = "data_exchange_revision"

    /// 記録側。小さく、これだけで解説と演習が揃う。
    private static let _recordFolders = ["metadata", "inf6_knowledge_cards", "inf6_pdf_details"]

    /// 運ばないもの。
    ///
    /// 生成の実行記録は、その端末で何がいつ動いたかを残すためのものである。
    /// 相手の端末に持って行っても意味がなく、件数だけが増える。
    private static let _excludedPrefixes = [
        "metadata/settings/drill_execution",
        "metadata/settings/drill_llm_invocation",
        "metadata/settings/runtime_error_events",
        "metadata/settings/venn_home_model_cache",
        "metadata/settings/export_ledger",
    ]
    /// 実体側。図と論文PDF。
    private static let _assetFolders = ["figures", "papers"]

    /// 束ねる元になる資格の並び。
    public static func knownSourceFamilies() -> [String] {
        let families = Inf6MetadataStore.listAll(domain: .syllabusPaperLinks)
            .compactMap { $0.key.split(separator: "|").first.map(String.init) }
        return Array(Set(families)).sorted()
    }

    // MARK: - 書き出した記録

    /// 一度書き出したものを覚えておく台帳。
    ///
    /// 論文PDFは、取り直さない限り中身が変わらない。毎回入れると、相手の
    /// 端末には既にあるものを何度も運ぶことになる。前回より新しいものだけを
    /// 対象にする。台帳は保存先に置き、受け渡しの対象からは外す。
    private static func _ledgerURL() -> URL {
        Inf6DataRoot.url()
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("settings", isDirectory: true)
            .appendingPathComponent("export_ledger.json")
    }

    private static func _loadLedger() throws -> [String: TimeInterval] {
        let url = _ledgerURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: TimeInterval].self, from: data)
    }

    private static func _saveLedger(_ ledger: [String: TimeInterval]) throws {
        let url = _ledgerURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }

    public static func loadHistory() -> [HistoryEntry] {
        Inf6MetadataStore.getCodable([HistoryEntry].self, domain: .settings, key: _historyKey) ?? []
    }

    public static func currentRevision() -> Int {
        Inf6MetadataStore.getCodable(Int.self, domain: .settings, key: _revisionKey) ?? 0
    }

    private static func _saveHistory(_ entries: [HistoryEntry]) throws {
        guard Inf6MetadataStore.putCodable(entries, domain: .settings, key: _historyKey) else {
            throw _error(3, "エクスポート／インポート履歴を保存できませんでした。")
        }
    }

    private static func _appendHistory(_ entry: HistoryEntry) throws {
        var entries = loadHistory()
        entries.insert(entry, at: 0)
        if entries.count > 100 {
            entries = Array(entries.prefix(100))
        }
        try _saveHistory(entries)
    }

    private static func _bumpRevision() throws {
        guard Inf6MetadataStore.putCodable(currentRevision() + 1, domain: .settings, key: _revisionKey) else {
            throw _error(4, "インポート後の更新記録を保存できませんでした。")
        }
    }

    // MARK: - 書き出し

    /// 選ばれたフォルダの中に、ひとそろいを書き出す。
    @discardableResult
    public static func exportSet(
        into parentDirectory: URL,
        sourceFamilies: [String],
        everything: Bool = false,
        commitImmediately: Bool = true,
        progress: ((String) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> ExportSummary {
        let fm = FileManager.default
        let root = Inf6DataRoot.url()

        let setName = "inf6_\(_deviceName())_\(_timestamp())"
        let destination = parentDirectory.appendingPathComponent(setName, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        progress?("対象を数えています")
        // 記録だけを持って行っても、図の無い端末では演習が成立しない。
        // 選べるようにしていたが、外して成り立つ使い方が無い。常に全部を入れる。
        let folders = _recordFolders + _assetFolders
        let all = _collectFiles(folders, under: root)
        let ledger = everything ? [:] : try _loadLedger()
        let files = all
            .filter { (ledger[$0.path] ?? 0) < $0.modifiedAt }
            .map { (path: $0.path, size: $0.size) }

        guard !files.isEmpty else {
            try? fm.removeItem(at: destination)
            throw _error(2, everything
                ? "書き出せるものがありません。"
                : "前回から変わったものはありません。")
        }

        let plan = _planParts(files: files, sourceFamilies: sourceFamilies)
        var partNames: [String] = []
        var fileCount = 0

        for (index, part) in plan.enumerated() {
            if isCancelled?() == true { throw CancellationError() }
            progress?("まとめています \(index + 1)/\(plan.count) — \(part.name)")
            let count = try _zipFiles(part.paths, under: root, to: destination.appendingPathComponent(part.name), isCancelled: isCancelled)
            guard count > 0 else { continue }
            partNames.append(part.name)
            fileCount += count
        }

        let manifest = Manifest(
            version: 1,
            device: _deviceName(),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            parts: partNames,
            fileCount: fileCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: destination.appendingPathComponent(_manifestName))

        var ledgerUpdates: [String: TimeInterval] = [:]
        for file in all where files.contains(where: { $0.path == file.path }) {
            ledgerUpdates[file.path] = file.modifiedAt
        }

        let summary = ExportSummary(
            directory: destination,
            partCount: partNames.count,
            fileCount: fileCount,
            archiveNames: partNames,
            ledgerUpdates: ledgerUpdates
        )
        if commitImmediately {
            try commitExport(summary)
        }
        return summary
    }

    public static func commitExport(_ summary: ExportSummary, destinationPath: String? = nil) throws {
        var updated = try _loadLedger()
        for (path, modifiedAt) in summary.ledgerUpdates {
            updated[path] = modifiedAt
        }
        try _saveLedger(updated)
        try _appendHistory(HistoryEntry(
            id: UUID(),
            operation: .export,
            happenedAt: ISO8601DateFormatter().string(from: Date()),
            destinationPath: destinationPath ?? summary.directory.path,
            archiveNames: summary.archiveNames,
            archiveCount: summary.partCount,
            fileCount: summary.fileCount
        ))
    }

    /// 書き出す対象を、保存先からの相対の道筋と大きさで集める。
    ///
    /// 追い出されたものは 0 バイトで写り、取り込んだ先で空の正本になる。
    /// 中身のあるものだけを対象にする。
    private static func _collectFiles(_ folders: [String], under root: URL) -> [(path: String, size: Int64, modifiedAt: TimeInterval)] {
        let fm = FileManager.default
        var result: [(path: String, size: Int64, modifiedAt: TimeInterval)] = []

        for folder in folders {
            let source = root.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: source.path),
                  let walker = fm.enumerator(
                    at: source,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .contentModificationDateKey]
                  )
            else { continue }

            for case let file as URL in walker {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .contentModificationDateKey])
                guard values?.isRegularFile == true,
                      let allocated = values?.fileAllocatedSize, allocated > 0 else { continue }

                let name = file.lastPathComponent
                guard name != ".DS_Store", !name.hasPrefix("._") else { continue }

                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                guard !_excludedPrefixes.contains(where: { relative.hasPrefix($0) }) else { continue }
                result.append((
                    path: relative,
                    size: Int64(allocated),
                    modifiedAt: values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                ))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// 分野とノードで束ね、目安の大きさに達したところで組に切る。
    ///
    /// ノードに結び付かないもの（設定など）は最後に common としてまとめる。
    /// 落とすと取り込んだ側で設定が欠ける。
    private static func _planParts(
        files: [(path: String, size: Int64)],
        sourceFamilies: [String]
    ) -> [(name: String, paths: [String])] {

        // 論文の置き場の名前から、その論文が属する分野とノードを引く。
        var owner: [String: (family: String, node: String)] = [:]
        for family in sourceFamilies {
            guard let groups = try? Inf6EshikakuDrillPipeline.selectOriginPapers(sourceFamily: family)
            else { continue }
            for group in groups {
                for entry in group.entries {
                    let node = entry.syllabusNodeID ?? entry.domainPrefix
                    owner[entry.folderKey] = (family: family, node: node)
                }
            }
        }

        // 各ファイルを、道筋に含まれる置き場の名前で振り分ける。
        var byNode: [String: [(path: String, size: Int64)]] = [:]
        var common: [(path: String, size: Int64)] = []

        // 論文PDFの名前は題名から作られ、図の置き場の名前とは大文字小文字も
        // 区切りも違う。そのまま突き合わせると、図は束ねられるのにその論文の
        // PDF だけが別の組へ落ちる。両方を同じ形に均してから比べる。
        func flattened(_ text: String) -> String {
            String(text.lowercased().map { ch in
                (ch.isLetter || ch.isNumber) ? ch : "_"
            }).replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        }
        let flattenedOwner = owner.map { (key: flattened($0.key), place: $0.value) }

        for file in files {
            let haystack = flattened(file.path)
            var assigned = false
            for entry in flattenedOwner where !entry.key.isEmpty && haystack.contains(entry.key) {
                byNode["\(entry.place.family)_\(entry.place.node)", default: []].append(file)
                assigned = true
                break
            }
            if !assigned { common.append(file) }
        }

        // ノードを名前順に詰め、目安を超えたところで切る。ノード単体が目安を
        // 超えても割らない。割ると片方だけ届いたときに使えない。
        var parts: [(name: String, paths: [String])] = []
        var current: [String] = []
        var currentNodes: [String] = []
        var carried: Int64 = 0

        func flush() {
            guard !current.isEmpty, let first = currentNodes.first else { return }
            let name = currentNodes.count == 1
                ? "\(_safeName(first)).zip"
                : "\(_safeName(first))__\(_safeName(currentNodes[currentNodes.count - 1])).zip"
            parts.append((name: name, paths: current))
            current = []; currentNodes = []; carried = 0
        }

        for node in byNode.keys.sorted() {
            let entries = byNode[node] ?? []
            let size = entries.reduce(Int64(0)) { $0 + $1.size }
            if !current.isEmpty, carried + size > _targetPartBytes { flush() }
            current.append(contentsOf: entries.map(\.path))
            currentNodes.append(node)
            carried += size
        }
        flush()

        if !common.isEmpty {
            for chunk in _chunk(common) {
                let suffix = parts.isEmpty ? "" : String(format: "_%03d", parts.count + 1)
                parts.append((name: "common\(suffix).zip", paths: chunk))
            }
        }
        return parts
    }

    /// 目安の大きさで組に切る。
    private static func _chunk(_ files: [(path: String, size: Int64)]) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        var carried: Int64 = 0

        for file in files {
            // 既に目安を超えているなら、この1件から次の組を始める。
            if !current.isEmpty, carried + file.size > _targetPartBytes {
                chunks.append(current)
                current = []
                carried = 0
            }
            current.append(file.path)
            carried += file.size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 指定のファイルを集めて zip にする。
    ///
    /// - Returns: 入れたファイルの数。
    private static func _zipFiles(
        _ relativePaths: [String],
        under root: URL,
        to destination: URL,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Int {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("inf6_stage_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var copied = 0
        for relative in relativePaths {
            if isCancelled?() == true { throw CancellationError() }
            let source = root.appendingPathComponent(relative)
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            do {
                try fm.copyItem(at: source, to: target)
                copied += 1
            }
        }
        guard copied > 0 else { return 0 }

        try _zip(directory: staging, to: destination)
        return copied
    }

    /// ディレクトリを zip にする。
    ///
    /// NSFileCoordinator の forUploading はディレクトリを zip にして渡す。
    /// 追加の部品を持ち込まずに済む。
    private static func _zip(directory: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinatorError
        ) { zipped in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }

    // MARK: - 取り込み

    /// 選ばれた zip を保存先へ展開する。
    ///
    /// 束のうち届いた分だけでも取り込める。同じ名前のものは新しい方を残す。
    /// 古い内容で上書きすると、この端末で作ったものが消えたように見える。
    ///
    /// - Returns: 取り込んだ件数。
    @discardableResult
    public static func importArchives(
        at archives: [URL],
        progress: ((String) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Int {
        var restored = 0
        for (index, archive) in archives.enumerated() {
            if isCancelled?() == true { throw CancellationError() }
            progress?("取り込んでいます \(index + 1)/\(archives.count)")
            restored += try _importOne(archive, isCancelled: isCancelled)
        }
        try _bumpRevision()
        try _appendHistory(HistoryEntry(
            id: UUID(),
            operation: .import,
            happenedAt: ISO8601DateFormatter().string(from: Date()),
            destinationPath: Inf6DataRoot.url().path,
            archiveNames: archives.map(\.lastPathComponent),
            archiveCount: archives.count,
            fileCount: restored
        ))
        return restored
    }

    private static func _importOne(_ archive: URL, isCancelled: (() -> Bool)? = nil) throws -> Int {
        let accessed = archive.startAccessingSecurityScopedResource()
        defer { if accessed { archive.stopAccessingSecurityScopedResource() } }

        let data = try Inf6SafeFileRead.data(at: archive)
        let entries = try _ZipReader.entries(in: data)
        guard !entries.isEmpty else { return 0 }

        let fm = FileManager.default
        let root = Inf6DataRoot.url()
        var restored = 0

        for entry in entries {
            if isCancelled?() == true { throw CancellationError() }
            if entry.path.hasSuffix("/") { continue }
            guard !entry.path.hasPrefix("/"),
                  !entry.path.split(separator: "/").contains("..") else {
                throw _error(6, "安全でないzipのパスです: \(entry.path)")
            }
            // macOS は拡張属性を __MACOSX と「._名前」で持ち回す。そのまま
            // 展開すると中身のない相棒が保存先に散らばる。
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.contains("__MACOSX"),
                  !components.contains(where: { $0.hasPrefix("._") }),
                  components.last != ".DS_Store"
            else { continue }

            let content = try _ZipReader.contents(of: entry, in: data)

            let target = root.appendingPathComponent(entry.path)
            if let existing = try? target.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, existing > entry.modifiedAt {
                continue
            }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, options: .atomic)
            restored += 1
        }
        return restored
    }

    // MARK: - 補助

    private static func _deviceName() -> String {
        let raw = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return _safeName(raw)
    }

    private static func _safeName(_ raw: String) -> String {
        let mapped = raw.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_"
        }
        let name = String(mapped)
        return name.isEmpty ? "unnamed" : String(name.prefix(120))
    }

    private static func _timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter.string(from: Date())
    }

    private static func _error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Inf6DataExchange", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - zip の読み取り

/// zip を読むための最小限の実装。
///
/// 書き出しは NSFileCoordinator が引き受けるが、展開する仕組みは用意されて
/// いない。外の部品を持ち込まずに済ませるため、必要な範囲だけを自分で読む。
/// 対応するのは無圧縮と deflate の2つで、zip64 と暗号化は扱わない。
enum _ZipReader {

    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let modifiedAt: Date
    }

    static func entries(in data: Data) throws -> [Entry] {
        guard let directoryEnd = _endOfCentralDirectory(in: data) else {
            throw _error("zip の形式ではありません。")
        }
        let count = Int(_read16(data, directoryEnd + 10))
        var offset = Int(_read32(data, directoryEnd + 16))

        var result: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, _read32(data, offset) == 0x0201_4b50 else {
                throw _error("zipの中央目录が壊れています。")
            }

            let method = _read16(data, offset + 10)
            let time = _read16(data, offset + 12)
            let date = _read16(data, offset + 14)
            let compressed = Int(_read32(data, offset + 20))
            let uncompressed = Int(_read32(data, offset + 24))
            let nameLength = Int(_read16(data, offset + 28))
            let extraLength = Int(_read16(data, offset + 30))
            let commentLength = Int(_read16(data, offset + 32))
            let localOffset = Int(_read32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else {
                throw _error("zipのファイル名領域が壊れています。")
            }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            result.append(Entry(
                path: _strippedTopFolder(name),
                compressionMethod: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                modifiedAt: _date(dosDate: date, dosTime: time)
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    static func contents(of entry: Entry, in data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, _read32(data, header) == 0x0403_4b50 else {
            throw _error("zip の中身を読めません: \(entry.path)")
        }
        let nameLength = Int(_read16(data, header + 26))
        let extraLength = Int(_read16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw _error("zip が途中で切れています: \(entry.path)") }

        let payload = Data(data[start..<end])
        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try _inflate(payload, expecting: entry.uncompressedSize)
        default:
            throw _error("扱えない圧縮方式です: \(entry.path)")
        }
    }

    /// 保存先から見た道筋に直す。
    ///
    /// この端末の書き出しは一時フォルダごと固めるため「一時フォルダ名/metadata/…」
    /// の形で入る。一方、別の作りの書き出しは「metadata/…」から始まる。先頭を
    /// 無条件に落とすと、後者で1階層ずれて別の場所へ展開してしまう。
    /// 保存先の直下にある名前で始まっていれば、そのまま使う。
    private static let _knownTopFolders: Set<String> = [
        "metadata", "inf6_knowledge_cards", "inf6_pdf_details",
        "figures", "papers", "inf6_pdfs", "jdla", "microsoft",
    ]

    private static func _strippedTopFolder(_ path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return path }
        let head = String(path[path.startIndex..<slash])
        if _knownTopFolders.contains(head) { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func _inflate(_ data: Data, expecting size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)

        let written: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, size,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw _error("展開に失敗しました。") }
        return output.prefix(written)
    }

    private static func _endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 65_535)
        var index = data.count - 22
        while index >= lowest {
            if _read32(data, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    private static func _read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func _read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    private static func _date(dosDate: UInt16, dosTime: UInt16) -> Date {
        var components = DateComponents()
        components.year = Int(dosDate >> 9) + 1980
        components.month = Int((dosDate >> 5) & 0x0F)
        components.day = Int(dosDate & 0x1F)
        components.hour = Int(dosTime >> 11)
        components.minute = Int((dosTime >> 5) & 0x3F)
        components.second = Int(dosTime & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: components) ?? Date.distantPast
    }

    private static func _error(_ message: String) -> NSError {
        NSError(domain: "Inf6DataExchange.Zip", code: 10,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
