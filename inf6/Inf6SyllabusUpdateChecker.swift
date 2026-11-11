//
//  Inf6SyllabusUpdateChecker.swift
//  inf6
//
//  シラバス PDF の自動更新チェッカー。
//  - 公式サイトから発見した PDF URL セットを永続化し、次回起動時(または一定期間経過後)に
//    再スクレイプして新しい PDF が追加されていないかを検出する。
//  - @Observable なので SwiftUI ビューが自動的に再描画される。
//

import Foundation
import SwiftUI

// MARK: - Model

struct Inf6SyllabusCheckRecord: Codable {
    /// 最後にチェックした日時
    var lastCheckedAt: Date
    /// そのチェックで発見した PDF URL 文字列リスト
    var knownPDFURLStrings: [String]
}

// MARK: - Checker

@Observable
final class Inf6SyllabusUpdateChecker {

    // Singleton
    static let shared = Inf6SyllabusUpdateChecker()

    // MARK: - Observable state

    /// チェック中の officialURL キーセット
    var checkingURLKeys: Set<String> = []

    /// 更新が見つかった officialURL キーセット
    var updateAvailableURLKeys: Set<String> = []

    /// 更新あり → 新たに発見された URL リスト (officialURL key → [new PDF URLs])
    var newlyFoundURLs: [String: [URL]] = [:]

    /// 更新検知後のシラバス同期エラー（officialURL key → error message）。
    var syllabusSyncErrorByOfficialURL: [String: String] = [:]

    // MARK: - Exam schedule backing stored properties

    /// 試験スケジュール情報は対象ごとに独立保持する。
    /// 単一スロット共有だと E資格/G検定 が上書きし合うため禁止。
    var _examScheduleInfoByName: [String: Inf6ExamScheduleInfo] = [:]

    /// 試験スケジュール取得中フラグ（対象ごと）
    var _checkingExamScheduleNames: Set<String> = []

    /// 試験スケジュール取得エラー（対象ごと）
    var _examScheduleErrorByName: [String: String] = [:]

    // MARK: - Persistent records

    private(set) var records: [String: Inf6SyllabusCheckRecord] = [:]

    // MARK: - Configuration

    /// 自動チェックを走らせる間隔 (デフォルト 7 日)
    var checkIntervalSeconds: TimeInterval = 7 * 24 * 3600

    // MARK: - Init

    private init() {
        records = Self._load()
        // キャッシュ済みの試験スケジュール情報を復元
        _examScheduleInfoByName = Self._loadCachedSchedules()
    }

    // MARK: - Schedule cache (static helpers, accessible from init)

    static var _scheduleURL: URL? {
        try? Inf6UserSettingRootPaths.cacheFileURL("syllabus_exam_schedule_v2")
    }

    static func _loadCachedSchedules() -> [String: Inf6ExamScheduleInfo] {
        guard let url = _scheduleURL else { return [:] }
        return Inf6DiskJSON.load([String: Inf6ExamScheduleInfo].self, from: url) ?? [:]
    }

    // MARK: - Public API

    func lastChecked(for officialURL: URL) -> Date? {
        records[officialURL.absoluteString]?.lastCheckedAt
    }

    func needsCheck(for officialURL: URL) -> Bool {
        guard let rec = records[officialURL.absoluteString] else { return true }
        return Date().timeIntervalSince(rec.lastCheckedAt) > checkIntervalSeconds
    }

    func isChecking(for officialURL: URL) -> Bool {
        checkingURLKeys.contains(officialURL.absoluteString)
    }

    func hasUpdate(for officialURL: URL) -> Bool {
        updateAvailableURLKeys.contains(officialURL.absoluteString)
    }

    func newURLs(for officialURL: URL) -> [URL] {
        newlyFoundURLs[officialURL.absoluteString] ?? []
    }

    // MARK: - Record from main pipeline (call after discoverOfficialPDFs succeeds)

    @MainActor
    func recordDiscovery(officialURL: URL, foundURLs: [URL]) {
        let key = officialURL.absoluteString
        let previous = records[key]
        let knownSet = Set(previous?.knownPDFURLStrings ?? [])
        let foundStrings = foundURLs.map { $0.absoluteString }
        let newOnes = foundURLs.filter { !knownSet.contains($0.absoluteString) }

        // Accumulate — never drop URLs already known (they may have been removed temporarily)
        var merged = knownSet
        foundStrings.forEach { merged.insert($0) }

        records[key] = Inf6SyllabusCheckRecord(
            lastCheckedAt: Date(),
            knownPDFURLStrings: Array(merged)
        )
        Self._save(records)

        if !newOnes.isEmpty && previous != nil {
            // Only surface "update" when we have a prior baseline to compare against
            updateAvailableURLKeys.insert(key)
            newlyFoundURLs[key] = newOnes
        }
        _synchronizeDetectedSyllabusUpdate(officialURL: officialURL)
    }

    // MARK: - Background update check (auto, fires only when needed)

    func checkForUpdatesIfNeeded(officialURL: URL) {
        let key = officialURL.absoluteString
        guard !checkingURLKeys.contains(key) else { return }
        guard needsCheck(for: officialURL) else { return }
        _beginCheck(officialURL: officialURL)
    }

    // MARK: - Force check (user-triggered, always re-scrapes)

    func forceCheck(officialURL: URL) {
        let key = officialURL.absoluteString
        guard !checkingURLKeys.contains(key) else { return }
        _beginCheck(officialURL: officialURL)
    }

    // MARK: - Dismiss update badge

    @MainActor
    func dismissUpdate(for officialURL: URL) {
        let key = officialURL.absoluteString
        updateAvailableURLKeys.remove(key)
        newlyFoundURLs.removeValue(forKey: key)

        // Update "known" to include any newly found URLs so next check baseline is correct
        if let rec = records[key] {
            records[key] = Inf6SyllabusCheckRecord(
                lastCheckedAt: rec.lastCheckedAt,
                knownPDFURLStrings: rec.knownPDFURLStrings
            )
        }
        Self._save(records)
    }

    // MARK: - Internal

    private func _beginCheck(officialURL: URL) {
        let key = officialURL.absoluteString
        checkingURLKeys.insert(key)
        Task {
            await _performCheck(officialURL: officialURL)
        }
    }

    @MainActor
    private func _performCheck(officialURL: URL) async {
        let key = officialURL.absoluteString
        defer {
            checkingURLKeys.remove(key)
        }

        // Build targets — same logic as discoverOfficialPDFs
        var targets: [URL] = [officialURL]
        if let host = officialURL.host?.lowercased(), host.contains("jdla.org"),
           (officialURL.path.isEmpty || officialURL.path == "/") {
            if let u1 = URL(string: "https://www.jdla.org/certificate/engineer/") {
                targets.append(u1)
            }
            if let u2 = URL(string: "https://www.jdla.org/certificate/general/") {
                targets.append(u2)
            }
        }

        var merged: [URL] = []
        var seen = Set<String>()
        let builder = Inf6SyllabusPipelineBuilder()

        for t in targets {
            let found = await inf6DiscoverReachablePDFURLsScoped(
                builder: builder,
                officialURL: t,
                scopeKeywords: [],
                keywords: [],
                timeout: 30,
                maxConcurrency: 2
            )
            for u in found {
                if seen.insert(u.absoluteString).inserted {
                    merged.append(u)
                }
            }
        }

        guard !merged.isEmpty else {
            // Could not reach the site — update lastChecked anyway to avoid hammering
            if var rec = records[key] {
                rec.lastCheckedAt = Date()
                records[key] = rec
                Self._save(records)
            }
            return
        }

        let knownSet = Set(records[key]?.knownPDFURLStrings ?? [])
        let newOnes = merged.filter { !knownSet.contains($0.absoluteString) }

        // Persist updated record
        var merged2 = knownSet
        merged.map { $0.absoluteString }.forEach { merged2.insert($0) }
        records[key] = Inf6SyllabusCheckRecord(
            lastCheckedAt: Date(),
            knownPDFURLStrings: Array(merged2)
        )
        Self._save(records)
        _synchronizeDetectedSyllabusUpdate(officialURL: officialURL)

        if !newOnes.isEmpty && !knownSet.isEmpty {
            // Only flag "update" if we have a prior baseline
            updateAvailableURLKeys.insert(key)
            newlyFoundURLs[key] = newOnes
        }
    }

    private func _synchronizeDetectedSyllabusUpdate(officialURL: URL) {
        let key = officialURL.absoluteString
        let manifests = Inf6LearningFamilyManifestStore.loadAll().filter { manifest in
            let sources = manifest.officialSources + manifest.trendSources
            return sources.contains { raw in
                guard let url = URL(string: raw) else { return false }
                return url.absoluteString == key
                    || url.host?.lowercased() == officialURL.host?.lowercased()
            }
        }
        guard !manifests.isEmpty else { return }
        syllabusSyncErrorByOfficialURL.removeValue(forKey: key)
        Task {
            do {
                _ = try await Inf6SyllabusConceptSetSynchronizer.synchronize(manifests: manifests)
                await MainActor.run {
                    _ = self.syllabusSyncErrorByOfficialURL.removeValue(forKey: key)
                }
            } catch {
                await MainActor.run {
                    self.syllabusSyncErrorByOfficialURL[key] = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Persistence

    private static var _stateURL: URL? {
        try? Inf6UserSettingRootPaths.cacheFileURL("syllabus_update_checker_v1")
    }

    private static func _load() -> [String: Inf6SyllabusCheckRecord] {
        guard let url = _stateURL else { return [:] }
        return Inf6DiskJSON.load([String: Inf6SyllabusCheckRecord].self, from: url) ?? [:]
    }

    private static func _save(_ records: [String: Inf6SyllabusCheckRecord]) {
        guard let url = _stateURL else { return }
        try? Inf6DiskJSON.save(records, to: url)
    }
}

// MARK: - Relative date helper

extension Inf6SyllabusUpdateChecker {

    /// "3日前" / "今日" / "1時間前" などの相対日時文字列
    static func relativeString(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 {
            return Inf6Lang.text("たった今", "just now")
        } else if seconds < 3600 {
            let mins = Int(seconds / 60)
            return Inf6Lang.text("\(mins)分前", "\(mins) min ago")
        } else if seconds < 86400 {
            let hrs = Int(seconds / 3600)
            return Inf6Lang.text("\(hrs)時間前", "\(hrs) hr ago")
        } else {
            let days = Int(seconds / 86400)
            return Inf6Lang.text("\(days)日前", "\(days) days ago")
        }
    }
}

// MARK: - 試験日程 + 適用シラバス判定

/// GPT（web_search ツール使用）が返す試験スケジュール情報
struct Inf6ExamScheduleInfo: Codable, Equatable {
    /// 次回試験の表示用日時文字列  例: "2026年8月"
    var nextExamDate: String
    /// 次回試験 ID  例: "E2026#1"
    var nextExamId: String
    /// 次回試験の開始日（ISO 8601, YYYY-MM-DD）
    var nextExamStartDate: String
    /// 次回試験の終了日（ISO 8601, YYYY-MM-DD）
    var nextExamEndDate: String
    /// JDLA公式の適用シラバス改訂ID  例: "E2026#2" / "G2024#6"
    var applicableSyllabusVersion: String
    /// `schools_jdla.default.yaml` / `pdf_syllabi` の `syllabus_id` に対応する内部キー  例: "e2026"
    var applicableSyllabusId: String
    /// JDLA公式が現在公開している最新版の改訂ID
    var publishedSyllabusVersion: String
    /// 現在公開されている最新版に対応する内部 `syllabus_id`
    var publishedSyllabusId: String
    /// 根拠に使った URL
    var sourceURLs: [String]
    /// GPT が付加した補足情報
    var notes: String
    /// この情報を取得した日時
    var fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case nextExamDate
        case nextExamId
        case nextExamStartDate
        case nextExamEndDate
        case applicableSyllabusVersion
        case applicableSyllabusId
        case publishedSyllabusVersion
        case publishedSyllabusId
        case sourceURLs
        case notes
        case fetchedAt
    }

    init(
        nextExamDate: String,
        nextExamId: String,
        nextExamStartDate: String,
        nextExamEndDate: String,
        applicableSyllabusVersion: String,
        applicableSyllabusId: String,
        publishedSyllabusVersion: String,
        publishedSyllabusId: String,
        sourceURLs: [String],
        notes: String,
        fetchedAt: Date
    ) {
        self.nextExamDate = nextExamDate
        self.nextExamId = nextExamId
        self.nextExamStartDate = nextExamStartDate
        self.nextExamEndDate = nextExamEndDate
        self.applicableSyllabusVersion = applicableSyllabusVersion
        self.applicableSyllabusId = applicableSyllabusId
        self.publishedSyllabusVersion = publishedSyllabusVersion
        self.publishedSyllabusId = publishedSyllabusId
        self.sourceURLs = sourceURLs
        self.notes = notes
        self.fetchedAt = fetchedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextExamDate = try c.decode(String.self, forKey: .nextExamDate)
        nextExamId = try c.decode(String.self, forKey: .nextExamId)
        nextExamStartDate = try c.decodeIfPresent(String.self, forKey: .nextExamStartDate) ?? ""
        nextExamEndDate = try c.decodeIfPresent(String.self, forKey: .nextExamEndDate) ?? ""
        applicableSyllabusVersion = try c.decode(String.self, forKey: .applicableSyllabusVersion)
        applicableSyllabusId = try c.decode(String.self, forKey: .applicableSyllabusId)
        publishedSyllabusVersion = try c.decodeIfPresent(String.self, forKey: .publishedSyllabusVersion) ?? applicableSyllabusVersion
        publishedSyllabusId = try c.decodeIfPresent(String.self, forKey: .publishedSyllabusId) ?? applicableSyllabusId
        sourceURLs = try c.decodeIfPresent([String].self, forKey: .sourceURLs) ?? []
        notes = try c.decode(String.self, forKey: .notes)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
    }

    // MARK: - Convenience

    /// アプリで選択されているシラバス ID が適切かどうかを返す。
    /// `currentSyllabusId` は schools_jdla.default.yaml の course.syllabus_id と対応。
    func isCurrentSyllabusAppropriate(currentSyllabusId: String?) -> Bool {
        guard let cur = currentSyllabusId?.trimmingCharacters(in: .whitespaces),
              !cur.isEmpty else { return true }  // 未選択なら警告しない
        return cur.localizedCaseInsensitiveCompare(applicableSyllabusId) == .orderedSame
    }

    var preferredKnowledgeStructureVersionID: String {
        let published = publishedSyllabusVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !published.isEmpty { return published }
        let applicable = applicableSyllabusVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicable.isEmpty { return applicable }
        let publishedSubset = publishedSyllabusId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !publishedSubset.isEmpty { return publishedSubset }
        let applicableSubset = applicableSyllabusId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicableSubset.isEmpty { return applicableSubset }
        return ""
    }

    /// 構造データの保存・参照に使う、公式情報由来のシラバス識別子。
    /// 表示用の改訂番号（例: E2026#2）ではなく、対応するデータ識別子を優先する。
    var preferredKnowledgeStructureID: String {
        let applicable = applicableSyllabusId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicable.isEmpty { return applicable }
        let published = publishedSyllabusId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !published.isEmpty { return published }
        return ""
    }

    var legacyKnowledgeStructureVersionIDs: [String] {
        var result: [String] = []
        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
        func appendYear(in raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let parts = trimmed.split { !$0.isNumber }.map(String.init)
            guard let year = parts.first(where: { $0.count == 4 && ($0.hasPrefix("19") || $0.hasPrefix("20")) }) else { return }
            append(year)
        }

        append(applicableSyllabusId)
        append(publishedSyllabusId)
        appendYear(in: applicableSyllabusVersion)
        appendYear(in: publishedSyllabusVersion)

        let canonical = preferredKnowledgeStructureVersionID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.filter { !$0.isEmpty && $0 != canonical }
    }

    func daysUntilStart(from now: Date = Date()) -> Int? {
        let trimmed = nextExamStartDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let examDate = formatter.date(from: trimmed) else { return nil }
        let startOfNow = Calendar(identifier: .gregorian).startOfDay(for: now)
        let startOfExam = Calendar(identifier: .gregorian).startOfDay(for: examDate)
        return Calendar(identifier: .gregorian).dateComponents([.day], from: startOfNow, to: startOfExam).day
    }
}

extension Inf6SyllabusUpdateChecker {
    // MARK: - Observable state for exam schedule

    func examScheduleInfo(for examName: String) -> Inf6ExamScheduleInfo? {
        _examScheduleInfoByName[_scheduleKey(examName)]
    }

    func isCheckingExamSchedule(for examName: String) -> Bool {
        _checkingExamScheduleNames.contains(_scheduleKey(examName))
    }

    func examScheduleError(for examName: String) -> String? {
        _examScheduleErrorByName[_scheduleKey(examName)]
    }

    // MARK: - Trigger

    /// LLM (web_search 付き) を使って次回試験日程と適用シラバスを調査する。
    /// - Parameter examName: "E資格" / "G検定" など
    func fetchExamScheduleIfNeeded(examName: String) {
        let key = _scheduleKey(examName)
        guard !key.isEmpty else { return }
        guard !_checkingExamScheduleNames.contains(key) else { return }

        // 7日以内に取得済みならキャッシュを使う
        if let info = _examScheduleInfoByName[key],
           Date().timeIntervalSince(info.fetchedAt) < checkIntervalSeconds {
            return
        }

        _checkingExamScheduleNames.insert(key)
        _examScheduleErrorByName.removeValue(forKey: key)

        Task {
            await _performExamScheduleFetch(examName: examName, key: key)
        }
    }

    /// 強制再取得（キャッシュをクリアして再調査）
    func forceFetchExamSchedule(examName: String) {
        let key = _scheduleKey(examName)
        guard !key.isEmpty else { return }
        guard !_checkingExamScheduleNames.contains(key) else { return }
        _examScheduleInfoByName.removeValue(forKey: key)
        _saveExamSchedules(_examScheduleInfoByName)
        _checkingExamScheduleNames.insert(key)
        _examScheduleErrorByName.removeValue(forKey: key)
        Task {
            await _performExamScheduleFetch(examName: examName, key: key)
        }
    }

    func forceFetchExamScheduleAndWait(examName: String) async {
        let key = _scheduleKey(examName)
        guard !key.isEmpty else { return }
        guard !_checkingExamScheduleNames.contains(key) else { return }
        _checkingExamScheduleNames.insert(key)
        _examScheduleErrorByName.removeValue(forKey: key)
        await _performExamScheduleFetch(examName: examName, key: key)
    }

    // MARK: - Internal fetch

    @MainActor
    private func _performExamScheduleFetch(examName: String, key: String) async {
        defer { _checkingExamScheduleNames.remove(key) }

        // 現在日時（今日）を渡してハルシネーション抑制
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        let today = formatter.string(from: Date())

        let system = """
        あなたは日本ディープラーニング協会（JDLA）の資格試験スケジュールを調査するアシスタントです。
        web_search ツールを使って https://www.jdla.org/ の公式情報を必ず確認してください。
        重要: 質問された試験種別（E資格またはG検定）のみを回答してください。別の試験種別の情報を混入させないでください。
        回答は必ず以下の JSON 形式のみで返してください。前後の説明文は一切不要です。
        {
          "nextExamDate": "YYYY年M月頃",
          "nextExamId": "E20XX#N",
          "nextExamStartDate": "YYYY-MM-DD",
          "nextExamEndDate": "YYYY-MM-DD",
          "applicableSyllabusVersion": "JDLA公式の適用シラバス改訂ID。例: E2026#2 / G2024#6",
          "applicableSyllabusId": "内部 syllabus_id。例: e2026 / g2024",
          "publishedSyllabusVersion": "JDLA公式が現在公開している最新版の改訂ID。例: E2026#2 / G2024#6",
          "publishedSyllabusId": "現在公開されている最新版に対応する内部 syllabus_id。例: e2026 / g2024",
          "sourceURLs": ["https://..."],
          "notes": "試験申込期間・適用版の根拠・その他補足（200字以内）"
        }
        日付は必ず JDLA 公式にある実日付を入れてください。不明なら推測せず失敗してください。
        sourceURLs は JDLA 公式 URL のみを入れてください。
        """

        let user = """
        今日は \(today) です。
        「\(examName)」（JDLA の資格試験）の**次回試験**はいつですか？
        ※「\(examName)」のみを調べてください。G検定・E資格を混同しないでください。
        その試験に適用されるシラバスのバージョン（2024版か2026版か等）も調べてください。
        JDLA公式サイト（https://www.jdla.org/certificate/）を web_search で確認し、JSON のみで回答してください。
        """

        do {
            let raw = try await Inf6OpenAIWebSearch.ask(
                system: system,
                user: user
            )

            // JSON 部分だけ抽出（GPT が余分なテキストを付けた場合に対応）
            let jsonString = _extractJSON(from: raw)
            guard let data = jsonString.data(using: .utf8) else {
                throw NSError(domain: "Inf6Syllabus", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to encode GPT response as UTF-8"])
            }

            struct _Raw: Decodable {
                var nextExamDate: String
                var nextExamId: String
                var nextExamStartDate: String
                var nextExamEndDate: String
                var applicableSyllabusVersion: String
                var applicableSyllabusId: String
                var publishedSyllabusVersion: String
                var publishedSyllabusId: String
                var sourceURLs: [String]
                var notes: String
            }
            let r = try JSONDecoder().decode(_Raw.self, from: data)
            let info = Inf6ExamScheduleInfo(
                nextExamDate: r.nextExamDate,
                nextExamId: r.nextExamId,
                nextExamStartDate: r.nextExamStartDate,
                nextExamEndDate: r.nextExamEndDate,
                applicableSyllabusVersion: r.applicableSyllabusVersion,
                applicableSyllabusId: r.applicableSyllabusId,
                publishedSyllabusVersion: r.publishedSyllabusVersion,
                publishedSyllabusId: r.publishedSyllabusId,
                sourceURLs: r.sourceURLs,
                notes: r.notes,
                fetchedAt: Date()
            )
            _examScheduleInfoByName[key] = info
            _examScheduleErrorByName.removeValue(forKey: key)
            _saveExamSchedules(_examScheduleInfoByName)
            _persistExamDeadlineIfPossible(info, examName: examName)

        } catch {
            _examScheduleErrorByName[key] = error.localizedDescription
        }
    }

    private func _scheduleKey(_ examName: String) -> String {
        examName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - JSON extraction helper

    private func _extractJSON(from text: String) -> String {
        // GPT がコードブロックや前置き付きで返した場合に JSON 部分だけ切り出す
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    // MARK: - Persistence for exam schedule

    func _saveExamSchedules(_ infos: [String: Inf6ExamScheduleInfo]) {
        guard let url = Self._scheduleURL else { return }
        try? Inf6DiskJSON.save(infos, to: url)
    }

    private func _persistExamDeadlineIfPossible(_ info: Inf6ExamScheduleInfo, examName: String) {
        let deadlineID: String
        switch examName {
        case "E資格":
            deadlineID = "e-shikaku"
        case "G検定":
            deadlineID = "g-kentei"
        case "AI-102":
            deadlineID = "ai-102"
        case "AI-103":
            deadlineID = "ai-103"
        default:
            return
        }

        let trimmed = info.nextExamStartDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var deadlines = Inf6ExamDeadlineStore.load().filter { $0.examID != deadlineID }
        deadlines.append(.init(examID: deadlineID, scheduledAt: "\(trimmed)T00:00:00Z"))
        Inf6ExamDeadlineStore.save(deadlines)
    }
}

// MARK: - Backing stored properties (workaround: @Observable cannot store computed-only)
// @Observable マクロは stored property を必要とするため、
// extension では直接 @Observable プロパティを宣言できない。
// そのため Inf6SyllabusUpdateChecker 本体に追加する。
// （このファイルでは typealias で型エイリアスのみ定義し、
//   本体側の @State ラッパーとして機能させる）

// MARK: - Web search wrapper

/// OpenAI Responses API を web_search ツール付きで呼び出す薄いラッパー。
/// UIKit / SwiftUI に依存しないため Foundation + URLSession のみ使用する。
enum Inf6OpenAIWebSearch {

    enum Err: Error, LocalizedError {
        case noAPIKey
        case httpError(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey:         return "OpenAI API キーが設定されていません。"
            case .httpError(let c, let m): return "HTTP \(c): \(m)"
            case .emptyResponse:    return "GPT から空のレスポンスが返されました。"
            }
        }
    }

    static func ask(system: String, user: String) async throws -> String {
        // API キーを取得
        let key: String
        do {
            key = try OpenAIKeyStore.load()
        } catch {
            throw Err.noAPIKey
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw Err.noAPIKey }

        // モデルを解決
        let model = Inf6OpenAIModelResolver.resolvedModel()

        let config = try OpenAIClient.Config.default(model: model)
        let client = OpenAIClient(apiKey: trimmedKey, config: config)
        return try await client.generateText(
            messages: [
                .init(role: .system, text: system),
                .init(role: .user, text: user)
            ],
            options: .init()
        )
    }
}
