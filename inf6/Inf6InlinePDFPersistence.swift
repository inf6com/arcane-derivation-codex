import CryptoKit
import Foundation
import PDFKit
import SwiftUI

extension InlinePDFPagesView {
    // MARK: - 2) Generated overview persistence (paper.abstract.txt)


    func _abstractStoreURL() -> URL? {
        guard let base = _paperBaseDir() else { return nil }
        let key = _paperFolderKey()
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            let msg = "[InlinePDFPagesView] _abstractStoreURL: paper key is empty (url=\(_activeURL))"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }
        return base.appendingPathComponent("\(k).abstract.txt")
    }

    func _loadAbstractFromDisk() -> Inf6ExtraNote {
        guard let u = _abstractStoreURL() else { return Inf6ExtraNote(text: "") }

        #if os(iOS)
        let didAccess = u.startAccessingSecurityScopedResource()
        defer { if didAccess { u.stopAccessingSecurityScopedResource() } }
        #endif

        let fm = FileManager.default
        let existsOnDisk = fm.fileExists(atPath: u.path)

        let data = _readFileDataCoordinated(u)

        if data == nil, existsOnDisk {
            let msg = "[InlinePDFPagesView] _loadAbstractFromDisk: coordinated read failed: \(u)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
        }

        guard let data, !data.isEmpty else { return Inf6ExtraNote(text: "") }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard Inf6AssetsAbstractPipeline.overviewMeetsCurrentContract(text) else {
            return Inf6ExtraNote(text: "")
        }
        return Inf6ExtraNote(text: text)
    }

    func _saveAbstractToDisk(_ text: String) {
        guard let u = _abstractStoreURL() else { return }
        let payload = text

        DispatchQueue.global(qos: .utility).async {
            #if os(iOS)
            let didAccess = u.startAccessingSecurityScopedResource()
            defer { if didAccess { u.stopAccessingSecurityScopedResource() } }
            #endif

            guard let data = payload.data(using: .utf8) else {
                let msg = "[InlinePDFPagesView] _saveAbstractToDisk: failed to encode UTF-8"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
                return
            }

            var coordError: NSError? = nil
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: u, options: .forReplacing, error: &coordError) { writeURL in
                do {
                    try data.write(to: writeURL, options: [.atomic])
                } catch {
                    let msg = "[InlinePDFPagesView] _saveAbstractToDisk: failed to write abstract: \(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }
            if let coordError {
                let msg = "[InlinePDFPagesView] _saveAbstractToDisk: write coordination failed: \(coordError)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        }
    }

    func _deleteAbstractFile() {
        guard let u = _abstractStoreURL() else { return }

        DispatchQueue.global(qos: .utility).async {
            #if os(iOS)
            let didAccess = u.startAccessingSecurityScopedResource()
            defer { if didAccess { u.stopAccessingSecurityScopedResource() } }
            #endif

            let fm = FileManager.default
            var delErr: NSError? = nil
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: u, options: .forDeleting, error: &delErr) { delURL in
                do {
                    try fm.removeItem(at: delURL)
                } catch {
                    // “無い” は「既に削除済み」であって失敗ではない
                    let ns = error as NSError
                    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError { return }

                    let msg = "[InlinePDFPagesView] _deleteAbstractFile: failed to delete: \(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }
            if let delErr {
                // 協調削除が失敗したら、ここは失敗として表に出す
                let msg = "[InlinePDFPagesView] _deleteAbstractFile: delete coordination failed: \(delErr)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        }
    }

    func _scheduleAbstractSave(_ text: String) {
        _abstractSaveTask?.cancel()
        _abstractSaveTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            _saveAbstractToDisk(text)
        }
    }

    func _paperMetadataSidecarCandidates() -> [URL] {
        let stem = _activeURL.deletingPathExtension()
        return [
            stem.appendingPathExtension("papermeta.json"),
            _activeURL.appendingPathExtension("papermeta.json"),
            stem.appendingPathExtension("json"),
            _activeURL.appendingPathExtension("json"),
        ]
    }


    /// サイドカーが無いときに、論文レコードへ保存された Abstract を使う。
    ///
    /// `.papermeta.json` を書くのは保存ボタン経路だけで、集中特訓の起源探索が
    /// 取得した論文はその経路を通らない。そのままでは要旨欄が常に空になるため、
    /// PDF のファイル名から論文レコードを引き当てて Abstract を取り出す。
    func _abstractFromCorePaperStore() -> String {
        let stemKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(
            from: _activeURL.deletingPathExtension().lastPathComponent
        )
        guard !stemKey.isEmpty else { return "" }

        for record in Inf6MetadataStore.listAllCodable(Inf6CorePaper.self, domain: .papers) {
            let paper = record.value
            guard let abstract = paper.abstract?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !abstract.isEmpty else { continue }
            let keys = [
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.title),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? ""),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.id),
            ].filter { !$0.isEmpty }
            for key in keys where stemKey == key
                || stemKey.hasPrefix(key + "_")
                || key.hasPrefix(stemKey + "_") {
                return abstract
            }
        }
        return ""
    }

    func _loadSourceAbstractFromMetadata() -> Inf6ExtraNote {
        let fm = FileManager.default
        guard let sidecarURL = _paperMetadataSidecarCandidates().first(where: {
            fm.fileExists(atPath: $0.path)
        }) else {
            return Inf6ExtraNote(text: _abstractFromCorePaperStore())
        }

        #if os(iOS)
        let didAccess = sidecarURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sidecarURL.stopAccessingSecurityScopedResource() } }
        #endif

        let existsOnDisk = fm.fileExists(atPath: sidecarURL.path)
        guard let data = _readFileDataCoordinated(sidecarURL), !data.isEmpty else {
            if existsOnDisk {
                let msg = "[InlinePDFPagesView] _loadSourceAbstractFromMetadata: coordinated read failed: \(sidecarURL)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
            return Inf6ExtraNote(text: _abstractFromCorePaperStore())
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            guard let root = json as? [String: Any] else {
                let msg = "[InlinePDFPagesView] _loadSourceAbstractFromMetadata: JSON root is not an object: \(sidecarURL)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
                return Inf6ExtraNote(text: _abstractFromCorePaperStore())
            }

            let rootAbstract = String(describing: root["abstract"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawAbstract: String = {
                guard let raw = root["raw"] as? [String: Any] else { return "" }
                return String(describing: raw["abstract"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }()
            let text = !rootAbstract.isEmpty ? rootAbstract : rawAbstract
            return Inf6ExtraNote(text: text.isEmpty ? _abstractFromCorePaperStore() : text)
        } catch {
            let msg = "[InlinePDFPagesView] _loadSourceAbstractFromMetadata: JSON decode failed: \(sidecarURL) error=\(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return Inf6ExtraNote(text: _abstractFromCorePaperStore())
        }
    }

    // MARK: - 3) Per-page notes persistence (pN.notes.json)

    // MARK: - Notes JSON page discovery (JSON-backed page list)

    /// Notes JSON file URL without creating the notes directory.
    /// Notes JSON canonical file URL (legacy) without creating the notes directory.
    func _notesStoreURLNoCreate(page: Int) -> URL? {
        guard let base = _paperBaseDir() else { return nil }
        let dir = base.appendingPathComponent("mini", isDirectory: true)
        let pageNumber = page + 1
        return dir.appendingPathComponent("p\(pageNumber).notes.json")
    }

    /// Notes JSON candidate URLs (legacy + pN.<k>.notes.json) without creating the notes directory.
    /// Order is stable: legacy first, then pN.1, pN.2, ...
    func _notesStoreURLsNoCreate(page: Int) -> [URL] {
        guard let base = _paperBaseDir() else { return [] }
        let dir = base.appendingPathComponent("mini", isDirectory: true)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            // Directory not present yet -> only legacy path is meaningful.
            if let legacy = _notesStoreURLNoCreate(page: page) {
                return [legacy]
            }
            return []
        }

        let pageNumber = page + 1
        let legacyName = "p\(pageNumber).notes.json"
        let legacyURL = dir.appendingPathComponent(legacyName)

        // Collect pN.<k>.notes.json where <k> is a positive integer.
        var extras: [(k: Int, url: URL)] = []
        do {
            let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let prefix = "p\(pageNumber)."
            let suffix = ".notes.json"

            for u in entries {
                let name = u.lastPathComponent
                if name == legacyName { continue }
                guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }

                // name: pN.<k>.notes.json
                let middle = String(name.dropFirst(prefix.count).dropLast(suffix.count))
                guard let k = Int(middle), k >= 1 else { continue }
                extras.append((k: k, url: u))
            }
        } catch {
            // Enumeration failure should surface as I/O error but still allow legacy path.
            let msg = "[InlinePDFPagesView] _notesStoreURLsNoCreate: cannot enumerate notes dir: \(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
        }

        extras.sort { $0.k < $1.k }
        var out: [URL] = [legacyURL]
        out.append(contentsOf: extras.map { $0.url })
        return out
    }

    /// Returns true if the notes JSON exists on disk (or is an iCloud ubiquitous item).
    func _notesJSONExists(page: Int) -> Bool {
        let urls = _notesStoreURLsNoCreate(page: page)
        if urls.isEmpty { return false }
        let fm = FileManager.default
        for u in urls {
            if fm.fileExists(atPath: u.path) {
                return true
            }
        }
        return false
    }

    /// Enumerate pages that have notes JSON files (pN.notes.json). Returned values are 0-based page indexes.
    func _pagesBackedByNotesJSON(doc: PDFDocument?) -> [Int] {
        guard let base = _paperBaseDir() else { return [] }
        let dir = base.appendingPathComponent("mini", isDirectory: true)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        do {
            let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var out: [Int] = []
            out.reserveCapacity(entries.count)

            for u in entries {
                let name = u.lastPathComponent
                guard name.hasPrefix("p"), name.hasSuffix(".notes.json") else { continue }

                // Expected: p<N>.notes.json (N is 1-based)
                let core = String(name.dropFirst()) // drop leading 'p'
                guard let dot = core.firstIndex(of: ".") else { continue }
                let nStr = String(core[..<dot])
                guard let n = Int(nStr), n >= 1 else { continue }

                let idx = n - 1
                out.append(idx)
            }

            out = Array(Set(out)).sorted()
            if let doc {
                out = out.filter { $0 >= 0 && $0 < doc.pageCount }
            }
            return out
        } catch {
            let msg = "[InlinePDFPagesView] _pagesBackedByNotesJSON: cannot enumerate notes dir: \(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return []
        }
    }

    func _notesStoreURL(page: Int) -> URL? {
        guard let base = _paperBaseDir() else { return nil }
        let dir = base.appendingPathComponent("mini", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            let msg = "[InlinePDFPagesView] _notesStoreURL: cannot create notes dir: \(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }
        let pageNumber = page + 1
        return dir.appendingPathComponent("p\(pageNumber).notes.json")
    }

    func _loadExtraNotesFromDisk(page: Int) -> [Inf6ExtraNote] {
        // metadata file store first
        let pdfKey = _pdfBaseName(from: _activeURL)
        let dbKey = "\(pdfKey):\(page)"
        if let notes: [Inf6ExtraNote] = Inf6MetadataStore.getCodable([Inf6ExtraNote].self, domain: .notes, key: dbKey) {
            if !notes.isEmpty { return notes }
        }

        let urls = _notesStoreURLsNoCreate(page: page)
        if urls.isEmpty { return [] }

        var out: [Inf6ExtraNote] = []
        out.reserveCapacity(16)

        let fm = FileManager.default

        for u in urls {
            #if os(iOS)
            let didAccess = u.startAccessingSecurityScopedResource()
            defer { if didAccess { u.stopAccessingSecurityScopedResource() } }
            #endif


            let existsOnDisk = fm.fileExists(atPath: u.path)
            guard let data = _readFileDataCoordinated(u), !data.isEmpty else {
                if existsOnDisk {
                    let msg = "[InlinePDFPagesView] _loadExtraNotesFromDisk: coordinated read failed: \(u)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
                continue
            }

            do {
                let arr = try JSONDecoder().decode([Inf6ExtraNote].self, from: data)
                if !arr.isEmpty {
                    out.append(contentsOf: arr)
                }
            } catch {
                let msg = "[InlinePDFPagesView] _loadExtraNotesFromDisk: decode failed for: \(u) error=\(error)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
                continue
            }
        }

        return out
    }

    func _saveExtraNotesToDisk(page: Int, notes: [Inf6ExtraNote]) {
        // metadata file store
        let pdfKey = _pdfBaseName(from: _activeURL)
        let dbKey = "\(pdfKey):\(page)"
        Inf6MetadataStore.putCodable(notes, domain: .notes, key: dbKey)

        guard let url = _notesStoreURL(page: page) else { return }

        let payload = notes
        let accessURL = url
        DispatchQueue.global(qos: .utility).async {
            #if os(iOS)
            let didAccess = accessURL.startAccessingSecurityScopedResource()
            defer { if didAccess { accessURL.stopAccessingSecurityScopedResource() } }
            #endif

            guard let data = try? JSONEncoder().encode(payload) else {
                let msg = "[InlinePDFPagesView] _saveExtraNotesToDisk: encode failed (page=\(page))"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
                return
            }

            var coordError: NSError? = nil
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
                do {
                    try data.write(to: writeURL, options: [.atomic])
                } catch {
                    let msg = "[InlinePDFPagesView] _saveExtraNotesToDisk: write failed (page=\(page)) error=\(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }

            if let coordError {
                let msg = "[InlinePDFPagesView] _saveExtraNotesToDisk: coordination failed (page=\(page)) error=\(coordError)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        }
    }

    func _ensureExtraNotesLoaded(for page: Int) {
        if extraNotesByPage[page] != nil { return }

        // If the parent provides the notes source, use it as the source of truth.
        // Do NOT gate on pN.notes.json existence in this mode, because persistence is owned by the parent.
        if let hook = loadExtraNotes {
            if let loaded = hook(page) {
                extraNotesByPage[page] = loaded
                _notesLoadRetryCountByPage[page] = 0
            }
            return
        }

        // Only materialize state for pages that are backed by JSON (file exists or is ubiquitous).
        let noteURLs = _notesStoreURLsNoCreate(page: page)
        guard !noteURLs.isEmpty else { return }

        let fm = FileManager.default
        if !noteURLs.contains(where: { fm.fileExists(atPath: $0.path) }) {
            // No JSON -> do not create an empty in-memory entry.
            return
        }

        // At this point the JSON is local. Load it.
        let loaded = _loadExtraNotesResolved(page: page)
        extraNotesByPage[page] = loaded
        _notesLoadRetryCountByPage[page] = 0
    }

    func _loadExtraNotesResolved(page: Int) -> [Inf6ExtraNote] {
        if let hook = loadExtraNotes {
            if let loaded = hook(page) {
                return loaded
            }
        }
        return _loadExtraNotesFromDisk(page: page)
    }

    func _persistExtraNotes(page: Int, _ notes: [Inf6ExtraNote]) {
        if let hook = saveExtraNotes {
            hook(page, notes)
            return
        }
        _saveExtraNotesToDisk(page: page, notes: notes)
    }

    // MARK: - 4) Shared root helpers

    func _sharedRootDirForKnowledgeCards() -> URL? {
        guard let sharedRoot = try? Inf6LibraryView._sharedRootDir() else { return nil }
        do {
            try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        } catch {
            let msg = "[InlinePDFPagesView] _sharedRootDirForKnowledgeCards: cannot create shared root dir: \(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }
        return sharedRoot
    }

    func _paperFolderKey() -> String {
        Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: _pdfBaseName(from: _activeURL))
    }

    func _paperBaseDir() -> URL? {
        guard let rootDir = _sharedRootDirForKnowledgeCards() else {
            let msg = "[InlinePDFPagesView] storage disabled: shared root is unavailable"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }

        // Attempt an in-app repair for same-name folder conflicts (e.g. "inf6_knowledge_cards 2", "inf6_knowledge_cards 3").
        // This only merges when it is provably safe (no overwrites; identical files only). Otherwise it surfaces an error and disables storage.
        do {
            try _repairDuplicateLocalFoldersIfNeeded(rootDir: rootDir)
        } catch {
            let msg = "[InlinePDFPagesView] shared root folder repair failed: \(error.localizedDescription)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }

        // After repair attempt, re-check for remaining conflicts and fail closed if any still exist.
        do {
            let fm = FileManager.default
            let entries = try fm.contentsOfDirectory(
                at: rootDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            let canonical = Inf6KnowledgeCardsPaths.rootFolderName
            let conflicts: [String] = entries.compactMap { u in
                let name = u.lastPathComponent
                if name == canonical { return nil }
                if name.hasPrefix(canonical + " ") { return name }
                return nil
            }

            if !conflicts.isEmpty {
                let sorted = conflicts.sorted()
                let msg = "[InlinePDFPagesView] shared root folder conflict still present: found \(sorted.joined(separator: ", ")). Merge contents into \"\(Inf6KnowledgeCardsPaths.rootFolderName)\" and delete the duplicates."
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
                return nil
            }
        } catch {
            let msg = "[InlinePDFPagesView] _paperBaseDir: cannot enumerate shared root for conflict check: \(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }

        let root = rootDir.appendingPathComponent(Inf6KnowledgeCardsPaths.rootFolderName, isDirectory: true)
        let key = _paperFolderKey()
        guard !key.isEmpty else {
            let msg = "[InlinePDFPagesView] _paperBaseDir: paper folder key is empty (url=\(_activeURL))"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }

        let dir = root.appendingPathComponent(key, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            let msg = "[InlinePDFPagesView] _paperBaseDir: cannot create directory for: \(_activeURL.lastPathComponent) error=\(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }
    }


    // MARK: - iCloud folder repair (merge "<name> 2/3/4..." into "<name>" and delete extras)

    enum _LocalFolderRepairError: LocalizedError {
        case localDocumentsUnavailable
        case canonicalIsNotDirectory(URL)
        case numberedIsNotDirectory(URL)
        case conflictFileVsDirectory(dst: URL)
        case conflictDirectoryVsFile(dst: URL)
        case fileConflict(dst: URL, src: URL)
        case sourceDirectoryNotEmptyAfterMerge(URL)
        case failedToRemoveExtra(URL, underlying: Error)
        case unableToReadFileAttributes(a: URL, b: URL)
        case cryptoKitUnavailableForComparison(a: URL, b: URL)

        var errorDescription: String? {
            switch self {
            case .localDocumentsUnavailable:
                return "Shared root directory is unavailable."
            case .canonicalIsNotDirectory(let url):
                return "Canonical folder exists but is not a directory: \(url.path)"
            case .numberedIsNotDirectory(let url):
                return "Numbered folder exists but is not a directory: \(url.path)"
            case .conflictFileVsDirectory(let dst):
                return "Merge conflict: destination is a file but source is a directory: \(dst.path)"
            case .conflictDirectoryVsFile(let dst):
                return "Merge conflict: destination is a directory but source is a file: \(dst.path)"
            case .fileConflict(let dst, let src):
                return "Merge conflict: different files for the same path. dst=\(dst.path) src=\(src.path)"
            case .sourceDirectoryNotEmptyAfterMerge(let url):
                return "Source directory not empty after merge (unexpected): \(url.path)"
            case .failedToRemoveExtra(let url, let underlying):
                return "Failed to remove extra folder: \(url.path) (\(underlying.localizedDescription))"
            case .unableToReadFileAttributes(let a, let b):
                return "Unable to read file attributes for comparison: a=\(a.path) b=\(b.path)"
            case .cryptoKitUnavailableForComparison(let a, let b):
                return "CryptoKit is unavailable, cannot safely compare files for equality: a=\(a.path) b=\(b.path)"
            }
        }
    }

    func _repairDuplicateLocalFoldersIfNeeded(rootDir: URL) throws {
        try _mergeAndDeleteNumberedFoldersIfNeeded(baseName: Inf6KnowledgeCardsPaths.rootFolderName, docsDir: rootDir)
    }

    func _mergeAndDeleteNumberedFoldersIfNeeded(baseName: String, docsDir: URL) throws {
        let fm = FileManager.default

        let canonical = docsDir.appendingPathComponent(baseName, isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: canonical.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw _LocalFolderRepairError.canonicalIsNotDirectory(canonical)
            }
        } else {
            try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
            print("[LocalFolderRepair] created canonical folder: \(canonical.path)")
        }

        // Sequential scan: if "<name> 3" does not exist, do not search "<name> 4" and beyond.
        var n = 2
        while true {
            let extraName = "\(baseName) \(n)"
            let extra = docsDir.appendingPathComponent(extraName, isDirectory: true)

            var extraIsDir: ObjCBool = false
            if !fm.fileExists(atPath: extra.path, isDirectory: &extraIsDir) {
                break
            }
            if !extraIsDir.boolValue {
                throw _LocalFolderRepairError.numberedIsNotDirectory(extra)
            }

            print("[LocalFolderRepair] merging extra folder into canonical: extra=\(extra.path) -> canonical=\(canonical.path)")
            try _mergeDirectoryContents(from: extra, into: canonical)

            do {
                try fm.removeItem(at: extra)
                print("[LocalFolderRepair] removed extra folder: \(extra.path)")
            } catch {
                throw _LocalFolderRepairError.failedToRemoveExtra(extra, underlying: error)
            }

            n += 1
        }
    }

    func _mergeDirectoryContents(from srcDir: URL, into dstDir: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(
            at: srcDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Create a deterministic conflict name inside the destination directory.
        func _conflictURL(dstDir: URL, originalName: String) throws -> URL {
            let base = (originalName as NSString).deletingPathExtension
            let ext = (originalName as NSString).pathExtension

            func makeName(_ n: Int) -> String {
                if ext.isEmpty {
                    return "\(base).conflict-\(n)"
                }
                return "\(base).conflict-\(n).\(ext)"
            }

            var n = 1
            while true {
                let cand = dstDir.appendingPathComponent(makeName(n), isDirectory: false)
                if !fm.fileExists(atPath: cand.path) {
                    return cand
                }
                n += 1
                if n > 9999 {
                    // Surface an actual failure rather than looping forever.
                    throw _LocalFolderRepairError.fileConflict(
                        dst: dstDir.appendingPathComponent(originalName),
                        src: dstDir.appendingPathComponent(makeName(n - 1))
                    )
                }
            }
        }

        for src in items {
            let name = src.lastPathComponent
            let dst = dstDir.appendingPathComponent(name, isDirectory: false)

            let rv = try src.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = rv.isDirectory ?? false

            if isDir {
                var dstIsDir: ObjCBool = false
                if fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir) {
                    if !dstIsDir.boolValue {
                        // Destination is a file but source is a directory: keep both by moving the source under a conflict name.
                        let conflict = try _conflictURL(dstDir: dstDir, originalName: name)
                        try fm.moveItem(at: src, to: conflict)
                        print("[LocalFolderRepair] moved directory conflict: \(src.path) -> \(conflict.path)")
                        continue
                    }
                } else {
                    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                }

                // Merge recursively.
                try _mergeDirectoryContents(from: src, into: dst)

                // After merge, if anything remains, do not throw; move the remaining directory under a conflict name.
                let remain = try fm.contentsOfDirectory(
                    at: src,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                if remain.isEmpty {
                    try fm.removeItem(at: src)
                } else {
                    let conflict = try _conflictURL(dstDir: dstDir, originalName: name)
                    try fm.moveItem(at: src, to: conflict)
                    print("[LocalFolderRepair] moved non-empty directory after merge as conflict: \(src.path) -> \(conflict.path)")
                }
            } else {
                var dstIsDir: ObjCBool = false
                if !fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir) {
                    try fm.moveItem(at: src, to: dst)
                    print("[LocalFolderRepair] moved: \(src.path) -> \(dst.path)")
                } else {
                    if dstIsDir.boolValue {
                        // Destination is a directory but source is a file: keep both by moving the source under a conflict name.
                        let conflict = try _conflictURL(dstDir: dstDir, originalName: name)
                        try fm.moveItem(at: src, to: conflict)
                        print("[LocalFolderRepair] moved file conflict (dst is dir): \(src.path) -> \(conflict.path)")
                        continue
                    }

                    let identical = try _areFilesIdentical(src, dst)
                    if identical {
                        try fm.removeItem(at: src)
                        print("[LocalFolderRepair] removed identical duplicate file: \(src.path)")
                    } else {
                        // Different files for the same path: keep both by moving the source under a conflict name.
                        let conflict = try _conflictURL(dstDir: dstDir, originalName: name)
                        try fm.moveItem(at: src, to: conflict)
                        print("[LocalFolderRepair] moved differing file as conflict: \(src.path) -> \(conflict.path)")
                    }
                }
            }
        }
    }

    func _areFilesIdentical(_ a: URL, _ b: URL) throws -> Bool {
        let fm = FileManager.default

        let attrA = try fm.attributesOfItem(atPath: a.path)
        let attrB = try fm.attributesOfItem(atPath: b.path)

        guard let sizeA = attrA[.size] as? NSNumber,
              let sizeB = attrB[.size] as? NSNumber else {
            throw _LocalFolderRepairError.unableToReadFileAttributes(a: a, b: b)
        }

        if sizeA != sizeB { return false }

        #if canImport(CryptoKit)
        let ha = try _sha256(a)
        let hb = try _sha256(b)
        return ha == hb
        #else
        throw _LocalFolderRepairError.cryptoKitUnavailableForComparison(a: a, b: b)
        #endif
    }

    #if canImport(CryptoKit)
    func _sha256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return Data(digest)
    }
    #endif

    func _readFileDataCoordinated(_ url: URL) -> Data? {
        var out: Data? = nil
        var coordError: NSError? = nil
        var readError: Error? = nil

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                out = try Inf6SafeFileRead.data(at: readURL)
            } catch {
                readError = error
                out = nil
            }
        }

        if let coordError {
            let msg = "[InlinePDFPagesView] _readFileDataCoordinated: coordination failed: \(coordError) url=\(url)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
        } else if let readError {
            // Avoid treating a missing optional file as an error; surface failures only when the item exists
            // (or is an iCloud ubiquitous item that should be downloadable).
            let fm = FileManager.default
            let existsOnDisk = fm.fileExists(atPath: url.path)
            if existsOnDisk {
                let msg = "[InlinePDFPagesView] _readFileDataCoordinated: read failed: \(readError) url=\(url)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        }
        return out
    }








}
