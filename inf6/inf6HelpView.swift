import Foundation
import SwiftUI

// MARK: - Security-scoped URL helper (cross-platform)

/// Execute `body` while accessing a security-scoped resource when needed.
/// - On macOS: uses `URL.withSecurityScope` if available in this codebase.
/// - On iOS/iPadOS: uses `startAccessingSecurityScopedResource()`.
@discardableResult
private func inf6WithSecurityScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    #if os(macOS)
    // `withSecurityScope` is unavailable on iOS; keep the call macOS-only.
    return try url.withSecurityScope {
        try body()
    }
    #else
    let started = url.startAccessingSecurityScopedResource()
    defer {
        if started { url.stopAccessingSecurityScopedResource() }
    }
    return try body()
    #endif
}


struct HelpSheetView: View {
    @Environment(\.dismiss) private var dismiss

    private struct _HelpSection: Identifiable {
        let id = UUID()
        let titleJa: String
        let titleEn: String
        let bodyJa: String
        let bodyEn: String
    }

    private var _sections: [_HelpSection] {
        [
            _HelpSection(
                titleJa: "1) 対象範囲と前提",
                titleEn: "1) Scope of this help",
                bodyJa: """
本ヘルプは inf6 アプリ（iOS / iPad / Designed for iPad(mac)）の運用手順を記載します。
対象環境:
- iPhone
- iPad
- Designed for iPad(mac)

inf6 は「ナレッジ・オペレーショナライゼーション」を行うシステムです。
知識を収集・圧縮・優先順位付け・問題化・測定・更新追随へ変換します。

姉妹アプリ:
- inf6 light（Electron製 Mac/Windowsデスクトップ版）
  正本（本アプリ）の機能サブセットを提供します。
  保存先はローカルフォルダ / 保存先 フォルダをユーザーが自由に選択します。

運用前提:
- 保存先 を利用します（保存先フォルダ管理）。
- APIキーは Keychain で管理します。
- 失敗は画面に明示されます（黙って成功にはしません）。

ここに記載した文は、すべて選択・コピーできます。
不一致を見つけた場合は、画面名と手順番号を指定してご連絡ください。
""",
                bodyEn: """
This help covers the inf6 app (iPhone, iPad, Designed for iPad on Mac).
inf6 operationalizes knowledge: collect → compress → prioritize → compose → measure → update.
Sister app: inf6 light (Electron desktop) provides a feature subset with user-selectable save folder.
Prerequisites: 保存先 + Keychain.
"""
            ),
            _HelpSection(
                titleJa: "2) ホーム画面（機能入口）",
                titleEn: "2) Home screen roles",
                bodyJa: """
ホームには次の主要機能があります。

ナレッジ・オペレーショナライゼーション・ループ:
- 収集する:
  arXiv / PubMed / ACL Anthology / ISCA Archive から論文を取得します。
- 整理する:
  保存済みPDFを開き、解説・知識カード・図表パイプラインを実行します。
- 問題を作る:
  蓄積した知識から MMA 演習を生成します。
- 測定する:
  生成済み問題に回答し、MasteryState を更新します。

その他:
- 保存先管理:
  検索元ごとの保存先マッピングを管理します。
- G検定 / E資格:
  コース別導線でシラバス操作・資料運用を行います。

「現在: ...」表示は、現在選択中の保存先マッピング先を示します。
""",
                bodyEn: """
Home provides the Knowledge Operationalization Loop:
Collect (arXiv/PubMed/ACL/ISCA) → Organize (PDF workspace) → Compose (MMA quiz) → Measure (quiz play).
Also: Destination Management, course-specific entries (G-test / E-cert).
"""
            ),
            _HelpSection(
                titleJa: "3) 保存先管理（マッピング運用）",
                titleEn: "3) Destination mapping",
                bodyJa: """
マッピングは「検索元 -> 保存先フォルダ」の対応です。

操作:
1. 変更: 既存の検索元に対する保存先フォルダを差し替えます。
2. 削除: マッピング定義のみ削除します（外部PDF本体は削除しません）。

注意:
- 1検索元に対して同時に有効な保存先は1つです。
- ACL と arXiv を同じフォルダに向けることは可能ですが、運用上は分離を推奨します。
- 権限切れ時は、同じフォルダを再選択して権限を再付与してください。
- 「削除」はマッピング定義のみを削除します。外部PDF本体は削除しません。
""",
                bodyEn: """
Mapping is "source -> destination folder".
Change replaces destination; Delete removes mapping definition only.
"""
            ),
            _HelpSection(
                titleJa: "4) 論文検索（取得・取り込み）",
                titleEn: "4) Paper search flow",
                bodyJa: """
検索手順:
1. 検索元を選択します。
2. キーワードまたは URL を入力します。
3. 候補一覧を確認し、取り込みを実行します。

URL入力:
- ACL/ISCA は論文ページURLとPDF URLの両方に対応します。
- URLが直接PDFでない場合は、対応するPDFリンクを解析して取得します。

取り込み時:
- 選択中の検索元に対応する保存先マッピングへ保存します。
- sidecar（.papermeta.json）を生成・更新します。
- source_url を記録します。
- arXiv は取り込み時に最新版確認を行い、必要に応じて最新版PDFを取得します。
""",
                bodyEn: """
Select source, enter keyword/URL, review results, then import.
On import, sidecar metadata is created/updated.
"""
            ),
            _HelpSection(
                titleJa: "5) 論文管理（保存済み一覧と要旨）",
                titleEn: "5) Paper management",
                bodyJa: """
論文管理は、保存済みPDFを扱う画面です。

表示構成:
- 左列: タイトル、特徴語、ファイル情報
- 右列: 要旨、source_url（クリックで外部表示）

主な操作:
1. マッピング行を選択して対象保存先を確定します。
2. ファイル名で絞り込みます。
3. 分類順 / ファイル名順を切り替えます。
4. ページ移動で大規模件数を分割表示します。
5. source_url をクリックして外部サイトを開きます。

要旨:
- sidecar の abstract を優先表示します。
- abstract が空の場合は自動補完処理を実行します。
- 補完に失敗した場合は失敗理由を明示します。
- 要旨は右列に表示し、一覧操作中でも参照できます。
""",
                bodyEn: """
Paper Management shows saved PDFs.
Left: title/features, right: abstract/source URL.
If abstract is empty, auto-completion runs.
"""
            ),
            _HelpSection(
                titleJa: "6) 論文サーベイ / PaperChat",
                titleEn: "6) Paper survey / PaperChat",
                bodyJa: """
PaperChat は段階進行型です。

標準ステップ:
1. 分野選択
2. 目的・制約整理
3. 候補提示
4. 絞り込み
5. 取り込み判断

入力規則:
- 未確定ステージで無効な操作は拒否し、理由を表示します。
- 処理失敗は黙って成功扱いにしません。
- 戻る操作で1ステップ前に戻せます。
- 候補提示時は要旨優先で比較し、取り込み対象を決定します。
""",
                bodyEn: """
PaperChat is stage-driven with explicit validation.
Invalid actions are rejected with visible reasons.
"""
            ),
            _HelpSection(
                titleJa: "7) Prompt Evaluation（応答制御/状態遷移評価）",
                titleEn: "7) Prompt Evaluation",
                bodyJa: """
Prompt Evaluation は、プロンプト品質を定量評価する機能です。

評価対象:
- 状態遷移: expected_next_state と next_state の一致
- 応答制約: must_include / must_not_include / max_chars

入力ケース項目:
- name
- user_message
- current_state
- expected_next_state（任意）
- must_include（任意）
- must_not_include（任意）
- max_chars（任意）

出力:
- ケースごとの passed / failures
- summary.total / passed / failed / pass_rate
- 回帰確認:
  同じケースを再実行して変更前後を比較できます。
""",
                bodyEn: """
Evaluates state transition correctness and response constraints with JSON test cases.
Returns per-case failures and summary pass rate.
"""
            ),
            _HelpSection(
                titleJa: "8) 保存データ仕様（ファイル構成）",
                titleEn: "8) Storage specification",
                bodyJa: """
保存される主なデータ:

1. PDF本体
- 保存先 上の保存先フォルダへ保存します。

2. 論文メタデータ（sidecar）
- <filename>.papermeta.json
- title / abstract / tags / source_url / provider / raw など

3. PDFキャッシュ（解説・ノート）
- storageRoot/inf6_pdf_details/<filename>.json
- 要旨、ページ別解説、ページ別追加ノート（extraNotesByPage）を含みます。

4. 知識カード
- storageRoot/inf6_knowledge_cards/<folderKey>/<pdfKey>.entities.json
- 図・表・式の検出アイテムと、それぞれの解説・構造化カードを含みます。

5. MMA データ
- storageRoot/mma/<sourceFamily>/quiz.json
- storageRoot/mma/<sourceFamily>/mastery.json など

6. 共通設定
- storageRoot/inf6_settings/selected_exams.json
- storageRoot/inf6_settings/exam_deadlines.json

7. 版管理（arXiv）
- <filename>.pdf.arxiv
- base_id / version / source_url など

8. APIキー
- Keychain 保存です（端末間で自動共有されない場合があります）。

すべての保存先は、ユーザーが設定した保存先フォルダを正本とします。
演習を生成・追加・削除した結果も同じ保存先へ直ちに保存されます。
保存に失敗した場合は成功扱いにせず、エラーを表示します。
ナレッジ一覧・削除・書き出し・取り込みは、ツールバーの「保存物」から行います。
""",
                bodyEn: """
Key artifacts are stored below the folder selected by the user: PDF,
.papermeta.json, inf6_pdf_details/<name>.json (abstract + notes),
inf6_knowledge_cards/<key>/<key>.entities.json (figure/table cards),
mma/<family>/quiz.json + mastery.json, inf6_settings/, API key in Keychain.
"""
            ),
            _HelpSection(
                titleJa: "9) PDF読解ワークスペース",
                titleEn: "9) PDF reading workspace",
                bodyJa: """
PDF読解ワークスペースでは、論文を開いて読みながらカード化できます。

主機能:
- ページ移動（サムネイル/スクロール）
- 範囲選択（選択テキストを基準に処理）
- 要旨生成（論文全体）
- 解説生成（選択範囲またはページ）
- 図表パイプライン（全ページ自動解析）
- 数式プレビュー（数式をミニPDFとして切り出し）
- 演習生成（保存済み情報から生成）
- ベクトル検索（意味類似で横断検索）

図表パイプライン（「図表を解析」ボタン）:
1. PDFの全ページから Figure / Table / Equation を自動検出します。
2. 検出アイテムごとに AI が構造化カードを生成します。
3. 検出した図・表・数式は件数制限を設けず、全件を保存します。中核と判定された
   エンティティには、LLMの重要度スコアを付与します。
4. 表（Table）の構造化カードには次が含まれます:
   - 表の再構築グリッド（列ヘッダー・行ラベル・セル値）
   - 太字の値はセル内で太字表示されます（元論文の太字を保持）
   - 見方のポイント（reading points）: 表の直下に和英 2〜4 箇条で表示
5. ポイント解説がまだない図・表・数式も画像カードとして表示し、カード内の
   「理解ポイントを追加」から追加生成できます。追加されたポイントにはAIマークを表示します。

実行には APIキー設定が必要です。
""",
                bodyEn: """
Read PDFs and generate abstract/explanations/cards/quiz/vector-search.
Figure/Table pipeline auto-detects all figures and tables across all pages.
Each table card includes: reconstructed grid, bold cell preservation, and reading points (EN+JA bullets).
Per-page isolation: one page failure does not abort the pipeline.
API key setup is required for AI actions.
"""
            ),
            _HelpSection(
                titleJa: "10) 図表パイプライン 詳細",
                titleEn: "10) Figure/Table pipeline details",
                bodyJa: """
図表パイプラインは §15 仕様に基づいた「整理する」フェーズの実装です。

検出ルール:
- キャプション形式「Figure N:」「Table N:」「Fig.N:」「表N：」などを正規表現で検出します。
- 件数制限は設けず、PDF全ページの図・表・数式を保持します。
- 同一ページに複数の表・図がある場合は独立してカード化します。

表カードの構造:
- 列名（英語・日本語）
- 行ラベルと各セルの値
- 太字セル: 元の論文で**太字**のセルは UI でも太字表示されます
- 見方のポイント（日本語・英語 2〜4 箇条）は表タイトルの直後に表示します

保存先:
- sharedRoot/inf6_knowledge_cards/<folderKey>/<pdfKey>.entities.json

再実行:
- 「図表を解析」ボタンを再度押すことで、最新コードで再解析できます。
- 再実行時は既存ノートがいったんクリアされてから上書きされます。

未解説エンティティ:
- 既存のポイント解説がない図・表・数式も、保存済み画像を表示します。
- カード内の「理解ポイントを追加」で、その図・表・数式を根拠にAI生成できます。
- 追加生成された理解ポイントにはAIマークが付き、通常演習JSONへ保存されます。
""",
                bodyEn: """
Detection: regex-based caption matching (Figure/Table N: patterns), with no per-page item limit.
Table cards: column names, row labels, cell values with bold preservation, reading points (EN+JA).
Reading points appear immediately after the table title, before the grid.
Storage: inf6_knowledge_cards/<key>/<key>.entities.json.
All detected figures, tables, and equations are retained. Core entities receive an LLM importance score.
Visuals without an existing understanding point remain visible and can generate one with “Add understanding point”.
Per-page/per-item isolation: failures skip the item without aborting the pipeline.
"""
            ),
            _HelpSection(
                titleJa: "11) OpenAI設定 / APIキー",
                titleEn: "11) OpenAI settings / API key",
                bodyJa: """
AI機能を使うには OpenAI APIキー（sk-...）を設定します。

手順:
1. 設定画面を開く
2. APIキーを入力
3. 設定済み表示とエラー無表示を確認

保存先:
- Keychain（端末依存）
- iCloudキーチェーンの設定によって端末間同期可否が変わります。
""",
                bodyEn: """
Set your OpenAI API key to use AI features.
The key is stored in Keychain.
"""
            ),
            _HelpSection(
                titleJa: "12) 権限と復元エラー",
                titleEn: "12) Permissions and restore errors",
                bodyJa: """
代表的なエラー:
- permission to view ...papermeta.json
- 保存先フォルダ復元失敗（bookmark不整合）

対処:
1. 保存先管理へ移動します。
2. 該当マッピングを「変更」します。
3. 同じフォルダを再選択して権限を再取得します。
4. 再度、論文管理へ戻って表示確認します。

補足:
- ブックマークが壊れている場合、復元失敗を表示し、再選択を要求します。
""",
                bodyEn: """
If permission/bookmark restore fails, re-select the mapped folder to re-grant access.
"""
            ),
            _HelpSection(
                titleJa: "13) Zip / Keychain 共有運用",
                titleEn: "13) Zip / Keychain shared operation",
                bodyJa: """
共有運用前提:
- 保存正本は端末内のローカル保存 root
- 端末間のデータ移送は Zip export/import
- APIキー共有は Keychain（パスワードとキーチェーン）の端末設定に依存

想定:
- PDF本体はアプリ管理外です
- アプリ生成データは storageRoot 側に保存します
- APIキーは Keychain 側で同期（端末設定に依存）

PDF の扱い:
- PDF の同一性はファイル名だけで判定します
- 同じファイル名なら同じ PDF とみなします
- ファイル名を変更した場合は別の PDF とみなします
- パスが違っても、アプリが黙って別ファイルへ差し替えることはありません
- 知識保存先は storageRoot に置かれますが、表示中の PDF 自体を勝手に別パスへ切り替えることはありません
- storageRoot はアプリ生成データの保存先であり、PDF の正本判定には使いません
- ツールバーの「保存物」から、storageRoot 上の保存済みナレッジと MMA 生成物を確認・削除・書き出し・取り込みできます

エクスポート:
- 「エクスポート」は現在の受け渡しセット全体を zip と manifest として書き出します
- 「すべて書き出す」のような別メニューはありません
- 保存先選択は、フォルダ読み込みではなく、生成済み zip ファイルを書き出すシステム画面で行います

インポート:
- 「インポート」は選択した zip アーカイブを復元します
- 復元後は同じ起動中セッションでも演習一覧が更新されます

端末間共有が必要な場合は、Zip export/import を実行してください。
""",
                bodyEn: """
Use Zip export/import for data sharing between devices. API key sharing depends on Keychain settings.
Export writes the current transfer set as zip files plus a manifest. There is no separate "export everything" menu.
Import restores selected zip archives and refreshes the drill list in the same running session.
"""
            ),
            _HelpSection(
                titleJa: "14) パフォーマンス運用",
                titleEn: "14) Performance operations",
                bodyJa: """
大量件数運用時の推奨:
- ページング単位で表示する
- フィルタで対象を絞る
- 不要な全件再分類を避ける
- 変更対象のみ再処理する

要旨・特徴語はキャッシュ/sidecarを利用し、毎回全件再計算しません。

図表パイプライン（大きい論文の場合）:
- 図表の多い論文（表3以上、図5以上）は処理に数分かかる場合があります。
- 画面を閉じずにお待ちください。処理はバックグラウンドで継続します。
- 大きな表（行数 10 以上）でも LazyVStack により UI はフリーズしません。

Designed for iPad (Mac) での起動:
- 初回起動時は 保存先 上の論文メタデータを並列読み込みします。
  論文数が多い場合（数百件以上）、「ナレッジ構造を読み込み中…」と表示されます。
  初回は数分かかる場合がありますが、読み込み結果はローカルにキャッシュされます。
- 2回目以降の起動はキャッシュから瞬時に読み込まれます。
- 論文の追加・削除を行った場合、次回起動時にキャッシュが自動更新されます。
""",
                bodyEn: """
For large libraries: use paging/filtering and incremental updates instead of full reprocessing.
For large papers: figure/table pipeline may take a few minutes; do not close the screen.
Large tables render freeze-free via lazy layout.

Designed for iPad (Mac) launch:
- On first launch, paper metadata is read from 保存先 in parallel.
  With many papers (hundreds+), "Loading knowledge structures…" is displayed.
  The first launch may take a few minutes; results are cached locally.
- Subsequent launches load from cache almost instantly.
- Cache auto-refreshes when papers are added or removed.
"""
            ),
            _HelpSection(
                titleJa: "15) トラブルシュート",
                titleEn: "15) Quick troubleshooting",
                bodyJa: """
Q1. URLクリックで開かない
A1. source_url が http/https 形式か確認してください。無効URLは開けません。

Q2. 要旨が空
A2. sidecar の abstract が空です。自動補完後に再表示してください。

Q3. 取り込みできない
A3. 保存先マッピングとフォルダ権限を確認してください。

Q4. 画面が遅い
A4. 表示件数を絞り、分類・補完を対象限定で実行してください。

Q5. 保存先復元エラー（Code=259）
A5. 保存済みブックマークが壊れています。保存先管理で同じフォルダを再選択してください。

Q6. 図表パイプラインで一部の表・図が表示されない
A6. 「図表を解析」ボタンで再実行してください。
    1件の失敗が他に波及しない設計ですが、再実行により最新コードで全ページを再処理します。
    論文によってはキャプション形式が非標準で検出できない場合があります。

Q7. 表の中のテキストが選択できない
A7. ノートカード全体にテキスト選択が有効になっています。
    表グリッド・解説テキスト・見方のポイントはすべて選択・コピーできます。

Q8. Designed for iPad (Mac) でスピナーのまま画面が表示されない
A8. 初回起動時に 保存先 上の論文データを読み込んでいます。
    論文数が多い場合は数分かかります。「ナレッジ構造を読み込み中…」と表示されます。
    2回目以降の起動ではキャッシュが有効なため数秒で表示されます。
""",
                bodyEn: """
Common checks: URL validity, abstract availability, destination permission, display scope.
Q6: Re-run the figure/table pipeline for missing items; per-item isolation prevents cascade failure.
Q7: Text selection is enabled on the entire note card including table grid and reading points.
Q8: On Mac (Designed for iPad), the first launch reads paper data from 保存先.
    With many papers, this may take a few minutes. Subsequent launches use local cache.
"""
            ),
            _HelpSection(
                titleJa: "16) inf6 light（デスクトップ版）との違い",
                titleEn: "16) inf6 light (desktop) differences",
                bodyJa: """
inf6 light は Electron 製の Mac/Windows デスクトップ版です。

inf6 light の特徴:
- 保存先: ローカルフォルダをユーザーが自由に選択
- 設定 > 「保存フォルダを選択」ボタンから Finder / ファイルエクスプローラで選択します
- 機能: 正本（本アプリ）のサブセット

inf6 light で利用できない機能（正本のみ）:
- ベクトル検索（ML埋め込みモデル）
- watchOS 連携
- PDF読解ワークスペースの一部高度機能

inf6 light と正本で共有するデータ:
- Zip export/import により、正本と inf6 light のナレッジ・MMAデータを移送できます。
- PDF同一性はファイル名で判定するため、フォルダパスが異なっても同じ論文として扱われます。
""",
                bodyEn: """
inf6 light (Electron desktop) key differences:
- Save folder: user-selectable local folder.
- Choose via Settings > "Select Save Folder" button (Finder/File Explorer).
- Feature subset: no vector search, no watchOS, some advanced PDF workspace features unavailable.
Data sharing uses Zip export/import.
"""
            ),
            _HelpSection(
                titleJa: "17) E資格 集中特訓演習",
                titleEn: "17) E-Cert Intensive Drill",
                bodyJa: """
ホーム画面上部の「E資格 集中特訓演習」ボタンから起動します。

演習は選択式ではありません。正しい内容を理解することが目的なので、
選択肢も正解表示も採点もありません。誤りの例は書きません。

画面の構成:
- シラバスのドメインごとにノードを一覧表示します
- 選択はすべて左端の印で行います。ノードは丸、論文は四角です
- 一覧の先頭にある「全ノード」「全論文」で、全ドメインをまとめて選べます
- ドメイン見出しの左端の丸を押すと、そのドメインだけをまとめて選べます
- 「操作メニュー」からは実行だけを行います。起源探索と演習生成の2つです
- 生成済み演習を選んで Live BP を開始すると、選択した演習の問題が順番に表示されます
- Live BP は、生成済み演習を選んだ後、画面上部の「Live BP」ボタンから明示的に開始します

生成中の表示:
- 画面上部に、処理中のノード名と現在の工程が並びます
- 工程は「論文PDFを用意しています」「解説を作成しています」
  「図・表・数式を作成しています」「演習を生成しています」と変わります
- 同時に処理するのは3件までです。多数を選んでも順に進みます
- 右端の「キャンセル」で、実行中のすべてを止められます
- arXiv が混雑して応答しない場合は、間隔を空けて自動で再試行します。
  それでも駄目な場合は「arxivRateLimit」として理由を表示します

起源の分類:
- 起源論文がある概念は、その論文を特定して紐づけます
- 起源論文が有料などで入手できない場合も、論文との紐づけは系譜として残した
  まま、解説と演習を生成します。演習が作れないまま止まることは
  ありません
- 論文の取得元は歯車の設定で選べます。出版社サイトのように成功しにくい先を
  外しておくこともできます

演習の見え方:
- 図・表・数式ごとにカードを作ります。同じ図表数式は一度だけ表示し、
  そこから学ぶべき点を「ポイント1」「ポイント2」とまとめて並べます
- 各ポイントは、要点を述べた見出し文と、箇条書きの解説で構成します
- 図の初期表示サイズは、図の中の文字が本文と同じ大きさに見えるよう
  自動調整します。図を押すと拡大します
- 各ポイントの Ask ボタンから、さらに詳しく / 用語をやさしく / 具体例で /
  順を追って の4種類の追加解説を求められます。結果はポイントの下に
  記録として残り、個別に削除できます

解説の構成:
- 通常の「解説」には要旨とコア理論を表示します。コア理論は箇条書きです
- Live BP 表示中は、コア理論本文は出しますが「コア理論」という見出しは表示しません
- 原論文の Abstract を取得できた場合は「要旨」として原文の和訳を載せます。
  取得できない場合のみ「論文概要」として生成した説明を載せます
- 「用語解説」は演習の後に置きます

論文PDF:
- ダウンロード済みの論文は「論文」ボタンから別ウィンドウで開きます。
  演習と並べて読めます

削除:
- 「演習を削除」は演習だけを消します。起源論文の紐づけは残ります
- 「起源論文を削除」は紐づけ自体を消します
""",
                bodyEn: """
Launch from the "E-Cert Intensive Drill" button at the top of the home screen.

These are not multiple-choice questions. The goal is to understand what is
correct, so there are no answer choices, no answer reveal, and no scoring.
Misconceptions are never written.

Screen layout:
- Nodes are listed per syllabus domain
- Everything is selected from the mark at the left: a circle for nodes, a square for papers
- "All nodes" and "All papers" at the top of the list select across every domain
- The circle at the left of a domain heading selects just that domain
- "Actions" only runs things: origin exploration and exercise generation
- Square selection is for generation and targeting. Selecting squares does not switch the screen into Live BP by itself
- Live BP starts only when you explicitly press the "Live BP" button after selecting generated exercises

While generating:
- The top of the screen lists the node being processed and its current step
- Steps read "Preparing the paper PDF", "Writing the explanation",
  "Building figures, tables, and equations", and "Generating exercises"
- At most three run at once; a large selection is processed in turn
- "Cancel" on the right stops everything that is running
- If arXiv is busy, requests are spaced out and retried automatically.
  If it still fails, the reason is shown as "arxivRateLimit"

Origin classification:
- Concepts with an origin paper are linked to that paper
- Download sources are selectable in the gear settings; sources that rarely
  succeed, such as publisher sites, can be turned off

How exercises appear:
- One card per figure, table, or equation. The same evidence appears only once,
  with its points grouped underneath as Point 1, Point 2, and so on
- Each point has a heading that states the point, followed by a bullet list
- The figure's initial size is chosen so that text inside it appears at the same
  size as the body text. Tap the figure to enlarge it
- The Ask button on each point requests further explanation: in more depth,
  explain the terms, with a concrete example, or step by step. Answers are kept
  under the point and can be deleted individually

Explanation:
- Normal "Explanation" shows the abstract and the core theory as a bullet list
- In Live BP, the core theory body is shown without the "Core Theory" heading
- When the original abstract can be fetched it is shown as "Abstract"; only when
  it cannot is a generated "Paper overview" shown instead
- "Terminology" is placed after the exercises

Paper PDF:
- Downloaded papers open in a separate window from the "Paper" button, so they
  can be read alongside the exercises

Deleting:
- "Delete exercises" removes only the exercises; the origin link remains
- "Delete origin paper" removes the link itself

Exercise generation and saving are independent for normal and Python exercises.
Selecting Python does not create, restore, or delete a normal exercise.
Generated and added exercises are persisted in the selected storage folder;
a failed save is reported as an error and is not treated as success.
"""
            ),
            _HelpSection(
                titleJa: "18) 公式リンク",
                titleEn: "18) Links",
                bodyJa: """
inf6.com:
https://inf6.com

本ヘルプ本文はすべて選択・コピー可能です。
""",
                bodyEn: """
inf6.com:
https://inf6.com
"""
            )
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Inf6Lang.text("inf6 ヘルプ（アプリ全体）", "inf6 Help (App-wide)"))
                        .font(.title2.weight(.bold))
                        .textSelection(.enabled)

                    Text(Inf6Lang.text(
                        "本ヘルプは、現行実装の操作仕様・保存仕様・エラー対処を網羅的に記載しています。",
                        "This help comprehensively describes current behavior, storage specs, and error handling."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                    ForEach(_sections) { s in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(Inf6Lang.text(s.titleJa, s.titleEn))
                                    .font(.headline)
                                    .textSelection(.enabled)

                                Text(Inf6Lang.text(s.bodyJa, s.bodyEn))
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .navigationTitle(Inf6Lang.text("ヘルプ", "Help"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inf6Lang.text("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}
