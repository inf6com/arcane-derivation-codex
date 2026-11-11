//
//  Inf6InlinePDFPagesView+UI.swift
//  inf6
//
//  Created by decopin on 2026/01/16.
//

import Foundation
import SwiftUI
import UIKit
import PDFKit

#if !os(iOS)
#error("Inf6InlinePDFPagesView+UI.swift is iOS-only. Remove this file from non-iOS targets.")
#endif

// MARK: - UI pieces split out from inf6InlinePDFView.swift

extension InlinePDFPagesView {

    // MARK: - 9) UI: Inline explanation editor (abstract + per-page notes)

    struct Inf6EditableNoteCard: View {
        @Binding var note: Inf6ExtraNote
        let fontSize: CGFloat
        @Binding var selectionMirror: String
        @Binding var isInteracting: Bool
        var allowsDelete: Bool = true
        let onDelete: () -> Void

        @State var cmd: Inf6RichTextCommand? = nil

        var body: some View {
            return VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    if allowsDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label(Inf6Lang.text("削除", "Delete"), systemImage: "trash")
                                .foregroundStyle(.blue)
                        }
                    }

                    Button { cmd = .deleteSelection } label: {
                        Image(systemName: "scissors")
                    }
                    .help(Inf6Lang.text("選択範囲を削除", "Delete selection"))

                    Menu {
                        Button(Inf6Lang.text("黄色", "Yellow")) { cmd = .setHighlight(.yellow) }
                        Button(Inf6Lang.text("緑", "Green")) { cmd = .setHighlight(.green) }
                        Button(Inf6Lang.text("ピンク", "Pink")) { cmd = .setHighlight(.pink) }
                        Divider()
                        Button(Inf6Lang.text("ハイライト解除", "Remove highlight")) { cmd = .setHighlight(nil) }
                    } label: {
                        Image(systemName: "highlighter")
                    }
                    .help(Inf6Lang.text("ハイライト（マーキング）", "Highlight"))

                    Button { cmd = .toggleUnderline } label: {
                        Image(systemName: "underline")
                    }
                    .help(Inf6Lang.text("下線", "Underline"))

                    Menu {
                        Button(Inf6Lang.text("赤", "Red")) { cmd = .setTextColor(.red) }
                        Button(Inf6Lang.text("青", "Blue")) { cmd = .setTextColor(.blue) }
                        Button(Inf6Lang.text("オレンジ", "Orange")) { cmd = .setTextColor(.orange) }
                        Divider()
                        Button(Inf6Lang.text("色解除", "Remove color")) { cmd = .setTextColor(nil) }
                    } label: {
                        Image(systemName: "paintbrush")
                    }
                    .help(Inf6Lang.text("文字色", "Text color"))
                }
                .buttonStyle(.borderless)
                .tint(.blue)

                Inf6RichTextNoteEditor(
                    note: $note,
                    fontSize: fontSize,
                    selectionMirror: $selectionMirror,
                    isInteracting: $isInteracting,
                    command: $cmd
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white)

                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .systemBlue).opacity(0.05))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
        }
    }

    struct Inf6StructuredTableNoteCard: View {
        let note: Inf6ExtraNote
        let fontSize: CGFloat
        var allowsDelete: Bool = true
        let onDelete: () -> Void

        private func cellFont(weight: Font.Weight = .regular) -> Font {
            .system(size: max(10, fontSize - 1), weight: weight)
        }

        private func normalizedMeaningLabel(_ s: String) -> String {
            s
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        private func columnMeaningMap(_ table: Inf6StructuredTable) -> [String: String] {
            Dictionary(uniqueKeysWithValues: table.columnMeanings.map {
                (normalizedMeaningLabel($0.label), $0.meaning)
            })
        }

        private func rowMeaningMap(_ table: Inf6StructuredTable) -> [String: String] {
            Dictionary(uniqueKeysWithValues: table.rowMeanings.map {
                (normalizedMeaningLabel($0.label), $0.meaning)
            })
        }

        private func displayColumns(_ table: Inf6StructuredTable, useMeaningLabels: Bool) -> [String] {
            if let structuredColumns = table.structuredColumns, !structuredColumns.isEmpty {
                return useMeaningLabels ? structuredColumns.map(\.labelJA) : structuredColumns.map(\.labelEN)
            }
            guard useMeaningLabels else { return table.columns }
            let meaningMap = columnMeaningMap(table)
            return table.columns.map { meaningMap[normalizedMeaningLabel($0)] ?? $0 }
        }

        private func displayRows(_ table: Inf6StructuredTable, useMeaningLabels: Bool) -> [Inf6StructuredTableRow] {
            if let structuredRows = table.structuredRows, !structuredRows.isEmpty {
                return structuredRows.map { row in
                    Inf6StructuredTableRow(
                        label: useMeaningLabels ? row.labelJA : row.labelEN,
                        values: row.values
                    )
                }
            }
            guard useMeaningLabels else { return table.rows }
            let meaningMap = rowMeaningMap(table)
            return table.rows.map { row in
                Inf6StructuredTableRow(
                    label: meaningMap[normalizedMeaningLabel(row.label)] ?? row.label,
                    values: row.values
                )
            }
        }

        private func sectionTitle(_ ja: String, _ en: String) -> String {
            Inf6Lang.text(ja, en)
        }

        private let _cellPadH: CGFloat = 8
        private let _cellPadV: CGFloat = 6

        private func _columnWidths(availableWidth: CGFloat, columnCount: Int) -> (label: CGFloat, value: CGFloat) {
            let screenW = max(220, availableWidth)
            let totalCols = max(columnCount, 2)
            if totalCols <= 2 {
                let labelW = screenW * 0.3
                let valueW = screenW * 0.7
                return (labelW, valueW)
            }
            let valueCols = CGFloat(totalCols - 1)
            let labelW = screenW * 0.25
            let valueW = (screenW - labelW) / valueCols
            return (labelW, valueW)
        }

        private func _cellContentWidth(_ width: CGFloat) -> CGFloat {
            max(0, width - (_cellPadH * 2))
        }

        private func descFont() -> Font {
            .system(size: max(8, fontSize - 4))
        }

        @ViewBuilder
        private func _headerCell(_ text: String, desc: String? = nil, width: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(cellFont(weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let desc, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(desc)
                        .font(descFont())
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(width: _cellContentWidth(width), alignment: .leading)
            .padding(.horizontal, _cellPadH)
            .padding(.vertical, _cellPadV)
            .background(Color(uiColor: .systemGray6))
            .overlay(alignment: .bottomTrailing) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            }
        }

        @ViewBuilder
        private func _labelCell(_ text: String, isLast: Bool, desc: String? = nil, width: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(cellFont(weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let desc, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(desc)
                        .font(descFont())
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(width: _cellContentWidth(width), alignment: .leading)
            .padding(.horizontal, _cellPadH)
            .padding(.vertical, _cellPadV)
            .background(Color(uiColor: .systemGray6))
            .overlay(alignment: .bottom) {
                if !isLast { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
            }
        }

        /// "**value**" 形式を検出して (表示テキスト, isBold) を返す
        private func _parseBold(_ raw: String) -> (String, Bool) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("**"), t.hasSuffix("**"), t.count > 4 {
                let inner = String(t.dropFirst(2).dropLast(2))
                return (inner, true)
            }
            return (t, false)
        }

        @ViewBuilder
        private func _valueCell(_ text: String, rowEven: Bool, width: CGFloat) -> some View {
            let (display, isBold) = _parseBold(text)
            Text(display)
                .font(cellFont(weight: isBold ? .bold : .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: _cellContentWidth(width), alignment: .leading)
                .padding(.horizontal, _cellPadH)
                .padding(.vertical, _cellPadV)
                .background(rowEven ? Color.white : Color(uiColor: .secondarySystemBackground))
                .overlay(alignment: .bottomTrailing) {
                    ZStack(alignment: .bottomTrailing) {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                    }
                }
        }

        private struct _TableData {
            var columns: [String]
            var rows: [Inf6StructuredTableRow]
            var colDescs: [String?]
            var rowDescs: [String?]
        }

        private func unifiedTableData(_ table: Inf6StructuredTable) -> _TableData {
            let useJA = Inf6Lang.isJapanese
            if let sc = table.structuredColumns, !sc.isEmpty,
               let sr = table.structuredRows, !sr.isEmpty {
                let cols = sc.map { useJA ? $0.labelJA : $0.labelEN }
                let rows = sr.map { Inf6StructuredTableRow(label: useJA ? $0.labelJA : $0.labelEN, values: $0.values) }
                let cds: [String?] = sc.map { col in
                    let d = useJA ? col.explanationJA : col.explanationEN
                    return d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : d
                }
                let rds: [String?] = sr.map { row in
                    let d = useJA ? row.explanationJA : row.explanationEN
                    return d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : d
                }
                return _TableData(columns: cols, rows: rows, colDescs: cds, rowDescs: rds)
            } else {
                let cols = displayColumns(table, useMeaningLabels: useJA)
                let rows = displayRows(table, useMeaningLabels: useJA)
                return _TableData(
                    columns: cols,
                    rows: rows,
                    colDescs: Array(repeating: nil, count: cols.count),
                    rowDescs: Array(repeating: nil, count: rows.count)
                )
            }
        }

        private func readingPoints(_ table: Inf6StructuredTable) -> [String]? {
            Inf6Lang.isJapanese
                ? (table.readingPointsJA ?? table.readingPointsEN)
                : (table.readingPointsEN ?? table.readingPointsJA)
        }

        private struct _ReadingPointRow: View {
            let pt: String
            let cellFont: Font
            var body: some View {
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(cellFont.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(pt)
                        .font(cellFont)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }

        /// Reads parent width via a transparent background and exposes it to the builder.
        /// Unlike GeometryReader, this does NOT constrain height — the inner content
        /// determines its own intrinsic height so tall rows are not clipped.
        private struct _WidthReader<Content: View>: View {
            let content: (CGFloat) -> Content
            @State private var width: CGFloat = 0

            init(@ViewBuilder content: @escaping (CGFloat) -> Content) {
                self.content = content
            }

            var body: some View {
                content(width)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: _WidthKey.self, value: proxy.size.width)
                        }
                    )
                    .onPreferenceChange(_WidthKey.self) { newValue in
                        if abs(newValue - width) > 0.5 {
                            width = newValue
                        }
                    }
            }
        }

        private struct _WidthKey: PreferenceKey {
            static var defaultValue: CGFloat = 0
            static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
                value = max(value, nextValue())
            }
        }

        @ViewBuilder
        private func tableGrid(
            columns: [String],
            rows: [Inf6StructuredTableRow],
            columnDescs: [String?]? = nil,
            rowDescs: [String?]? = nil
        ) -> some View {
            // Use a width-only reader so height is determined intrinsically by content.
            // Previously GeometryReader constrained height to its parent, clipping
            // tall rows (cells with descriptions wrap into multiple lines).
            _WidthReader { width in
                let widths = _columnWidths(availableWidth: width, columnCount: columns.count)
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { colIndex, col in
                            _headerCell(
                                col,
                                desc: columnDescs.flatMap { $0.indices.contains(colIndex) ? $0[colIndex] : nil },
                                width: colIndex == 0 ? widths.label : widths.value
                            )
                        }
                    }
                    // Rows
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 0) {
                            _labelCell(
                                row.label,
                                isLast: rowIndex == rows.count - 1,
                                desc: rowDescs.flatMap { $0.indices.contains(rowIndex) ? $0[rowIndex] : nil },
                                width: widths.label
                            )
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                _valueCell(value, rowEven: rowIndex.isMultiple(of: 2), width: widths.value)
                            }
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .textSelection(.enabled)
            }
        }

        @ViewBuilder
        var body: some View {
            if let table = note.structuredTable {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(table.title)
                                .font(.system(size: max(12, fontSize), weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(Inf6Lang.text("再構成表", "Reconstructed table"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        if allowsDelete {
                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                Label(Inf6Lang.text("削除", "Delete"), systemImage: "trash")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    // ── 見方のポイント（タイトル直後） ─────────────────
                    if let pts = readingPoints(table), !pts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(sectionTitle("見方のポイント", "Reading points"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                                _ReadingPointRow(pt: pt, cellFont: cellFont())
                            }
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // ── 言語別統合表（解説をセル内に表示） ────────────────────
                    let td = unifiedTableData(table)
                    tableGrid(
                        columns: td.columns,
                        rows: td.rows,
                        columnDescs: td.colDescs,
                        rowDescs: td.rowDescs
                    )
                }
                .padding(12)
                .textSelection(.enabled)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
        }
    }

    /// Inline editor used by the detail pane: source abstract + generated overview + page notes.
    struct _InlineExplanationSelectableTextView: View {
        @Binding var sourceAbstractNote: Inf6ExtraNote
        @Binding var overviewNote: Inf6ExtraNote
        @Binding var notes: [Inf6ExtraNote]
        let placeholder: String
        let fontSize: CGFloat
        @Binding var selectedText: String
        let noteSelectionMirror: (UUID) -> Binding<String>
        @Binding var isInteractingAnyEditor: Bool
        let onGenerateAbstract: () async -> Void
        let onAddExplanation: (_ selectedText: String) -> Void
        let onDeleteOverview: () -> Void
        let onRerunAssetsPipeline: (() -> Void)?
        let onDeletePaperEntity: (Inf6DocEntity) -> Void
        let entityIndexRefreshID: UUID
        var pdfKey: String? = nil
        var pdfTitleKey: String? = nil
        var currentPageIndex: Int? = nil

        @State var isGenerating: Bool = false


        func _trim(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        func _isLegacyTableNote(_ note: Inf6ExtraNote) -> Bool {
            guard note.structuredTable == nil else { return false }
            let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if trimmed == "表\n（なし）" || trimmed == "Tables\n(none)" {
                return false
            }
            let normalized = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
            return (
                normalized.hasPrefix("表\n名称:")
                && normalized.contains("\nポイント:")
            ) || (
                normalized.hasPrefix("Tables\nname:")
                && normalized.contains("\npoints:")
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if !placeholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Inf6Lang.text("要旨", "Abstract"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ZStack(alignment: .topLeading) {
                        Inf6EditableNoteCard(
                            note: $sourceAbstractNote,
                            fontSize: fontSize,
                            selectionMirror: noteSelectionMirror(sourceAbstractNote.id),
                            isInteracting: $isInteractingAnyEditor,
                            allowsDelete: false,
                            onDelete: {}
                        )

                        if sourceAbstractNote.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty,
                           !placeholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 6)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Inf6Lang.text("概略解説", "Overview"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Inf6EditableNoteCard(
                        note: $overviewNote,
                        fontSize: fontSize,
                        selectionMirror: noteSelectionMirror(overviewNote.id),
                        isInteracting: $isInteractingAnyEditor,
                        onDelete: {
                            onDeleteOverview()
                        }
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(Inf6Lang.text("解説", "Notes"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(notes.indices), id: \.self) { index in
                        let id = notes[index].id
                        let noteBinding = Binding<Inf6ExtraNote>(
                            get: { notes[index] },
                            set: { notes[index] = $0 }
                        )
                        if let fixedNote = notes[index].structuredTable {
                            Inf6StructuredTableNoteCard(
                                note: notes[index],
                                fontSize: fontSize,
                                onDelete: {
                                    #if canImport(UIKit)
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    #endif
                                    withAnimation {
                                        notes.removeAll(where: { $0.id == id })
                                    }
                                }
                            )
                            .id(fixedNote.title + id.uuidString)
                        } else if _isLegacyTableNote(notes[index]) {
                            Inf6LegacyStructuredTableNoteCard(
                                note: notes[index],
                                onDelete: {
                                    #if canImport(UIKit)
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    #endif
                                    withAnimation {
                                        notes.removeAll(where: { $0.id == id })
                                    }
                                },
                                onRerun: onRerunAssetsPipeline
                            )
                            .id("legacy-table-" + id.uuidString)
                        } else {
                            Inf6EditableNoteCard(
                                note: noteBinding,
                                fontSize: fontSize,
                                selectionMirror: noteSelectionMirror(id),
                                isInteracting: $isInteractingAnyEditor,
                                onDelete: {
                                    #if canImport(UIKit)
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    #endif
                                    withAnimation {
                                        notes.removeAll(where: { $0.id == id })
                                    }
                                }
                            )
                            .id(id.uuidString)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                let resolvedIndex: Inf6DocEntityIndex? = {
                    if let k = pdfKey, !k.isEmpty,
                       let idx = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: k) {
                        return idx
                    }
                    if let k = pdfTitleKey, !k.isEmpty, k != pdfKey,
                       let idx = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: k) {
                        return idx
                    }
                    return nil
                }()
                Group {
                    if let index = resolvedIndex {
                        let pageFilter: (Inf6DocEntity) -> Bool = { entity in
                            guard let p = currentPageIndex else { return true }
                            return entity.pageIndex == p
                        }
                        let figures = index.entities.filter { ($0.kind == .figure || $0.kind == .table) && pageFilter($0) }
                        let equations = index.entities.filter { $0.kind == .equation && pageFilter($0) }

                        if !figures.isEmpty {
                            _InlinePaperEntitySection(
                                heading: Inf6Lang.text("図表解説", "Figures & Tables"),
                                icon: "photo",
                                entities: figures,
                                fontSize: fontSize,
                                onDelete: onDeletePaperEntity
                            )
                        }

                        if !equations.isEmpty {
                            _InlinePaperEntitySection(
                                heading: Inf6Lang.text("数式解説", "Equations"),
                                icon: "function",
                                entities: equations,
                                fontSize: fontSize,
                                onDelete: onDeletePaperEntity
                            )
                        }
                    }
                }
                .id(entityIndexRefreshID)
            }
        }
    }

    struct _InlinePaperEntitySection: View {
        let heading: String
        let icon: String
        let entities: [Inf6DocEntity]
        let fontSize: CGFloat
        let onDelete: (Inf6DocEntity) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(heading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("(\(entities.count))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(entities) { entity in
                    _InlinePaperEntityRow(entity: entity, fontSize: fontSize) {
                        onDelete(entity)
                    }
                }
            }
        }
    }

    struct _InlinePaperEntityRow: View {
        let entity: Inf6DocEntity
        let fontSize: CGFloat
        let onDelete: () -> Void
        @State private var image: UIImage?
        @State private var loaded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: entity.kind == .equation ? "function" : (entity.kind == .table ? "tablecells" : "photo"))
                        .font(.system(size: fontSize - 3))
                        .foregroundStyle(entity.kind == .equation ? .blue : .orange)
                    Text(entity.title)
                        .font(.system(size: fontSize - 1, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: fontSize - 2, weight: .semibold))
                            .foregroundStyle(Color(uiColor: .systemBlue))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Inf6Lang.text("この図表数式を削除", "Delete this visual evidence"))
                }

                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                        )
                } else if entity.imagePath != nil && !loaded {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .frame(height: 80)
                        .frame(maxWidth: .infinity)
                }

                if let explanation = entity.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !entity.snippet.isEmpty {
                    Text(entity.snippet)
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground).opacity(0.5))
            )
            .onAppear {
                guard !loaded, let path = entity.imagePath else { return }
                loaded = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let url = Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(path)
                    let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else { return }
                    let downsampleOpts: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1200
                    ]
                    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts as CFDictionary) else { return }
                    let img = UIImage(cgImage: cgImage)
                    DispatchQueue.main.async { image = img }
                }
            }
            .onDisappear { image = nil }
        }
    }

    func _deletePaperEntity(_ entity: Inf6DocEntity) {
        let pdfKey = Self._entityPdfKey(for: _activeURL)
        guard let pdfKey, !pdfKey.isEmpty else {
            _ioLastError = "[InlinePDFPagesView] Cannot delete visual evidence: PDF key is unavailable."
            return
        }
        guard var index = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self,
            domain: .docEntities,
            key: pdfKey
        ) else {
            _ioLastError = "[InlinePDFPagesView] Cannot delete visual evidence: entity index is unavailable."
            return
        }
        guard let entityIndex = index.entities.firstIndex(where: { $0.id == entity.id }) else {
            _ioLastError = "[InlinePDFPagesView] Cannot delete visual evidence: entity was not found."
            return
        }

        let removed = index.entities.remove(at: entityIndex)
        Inf6MetadataStore.putCodable(index, domain: .docEntities, key: pdfKey)

        if let imagePath = removed.imagePath {
            let imageURL = Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(imagePath)
            do {
                try FileManager.default.removeItem(at: imageURL)
            } catch CocoaError.fileNoSuchFile {
                // The metadata deletion is complete; the referenced image was already absent.
            } catch {
                _ioLastError = "[InlinePDFPagesView] Cannot delete visual evidence image: \(error.localizedDescription)"
                return
            }
        }

        _entityIndexRefreshID = UUID()
        print("[InlinePDFPagesView] deleted visual evidence id=\(removed.id.uuidString) title=\(removed.title) pdfKey=\(pdfKey)")
    }

    struct Inf6LegacyStructuredTableNoteCard: View {
        let note: Inf6ExtraNote
        let onDelete: () -> Void
        let onRerun: (() -> Void)?

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Label(Inf6Lang.text("表", "Table"), systemImage: "tablecells")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label(Inf6Lang.text("削除", "Delete"), systemImage: "trash")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(Inf6Lang.text(
                        "この表ノートは旧形式で保存されており、現行仕様の構造化表を持っていません。",
                        "This table note was saved in the legacy format and does not contain the current structured table payload."
                    ))
                    .font(.callout)
                    .foregroundStyle(.primary)

                    Text(Inf6Lang.text(
                        "表を再表示するには、図表パイプラインを再実行してください。",
                        "Re-run the assets pipeline to regenerate and display the table."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let onRerun {
                        Button {
                            onRerun()
                        } label: {
                            Label(
                                Inf6Lang.text("図表パイプラインを再実行", "Re-run assets pipeline"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.red.opacity(0.28), lineWidth: 1)
                )
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // Merge selection text from PDF, detail pane, and math-card explanation editor,
    // avoiding obvious duplicates. This is used to enable/disable selection-based actions.
    var _selectionTextUnified: String {
        let a = pdfSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = detailSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = _miniCardSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fast paths
        if !a.isEmpty, b.isEmpty, c.isEmpty { return a }
        if a.isEmpty, !b.isEmpty, c.isEmpty { return b }
        if a.isEmpty, b.isEmpty, !c.isEmpty { return c }

        // Prefer non-empty sources while avoiding duplication.
        var parts: [String] = []
        parts.reserveCapacity(3)

        func appendIfUseful(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }

            for existing in parts {
                if existing == t { return }
                if existing.contains(t) { return }
            }
            // If the new text contains an existing part, replace it with the larger one.
            for i in 0..<parts.count {
                if t.contains(parts[i]) {
                    parts[i] = t
                    return
                }
            }
            parts.append(t)
        }

        appendIfUseful(a)
        appendIfUseful(b)
        appendIfUseful(c)

        if parts.isEmpty { return "" }
        if parts.count == 1 { return parts[0] }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 10) Layout (toolbar + body)

    var body: some View {
        GeometryReader { geo in
            _pdfSplitLayout(geo)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showThumbnailSidebar.toggle()
                    }
                } label: {
                    Image(systemName: showThumbnailSidebar ? "sidebar.leading" : "sidebar.left")
                }
                .accessibilityLabel(
                    Inf6Lang.text("ページサムネイルの表示切り替え", "Toggle thumbnail sidebar")
                )
            }

            if !showDetailPane {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showDetailPane = true
                        }
                    } label: {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                    }
                    .accessibilityLabel(
                        Inf6Lang.text("詳細ペインを表示", "Show detail pane")
                    )
                }
            }
        }
        // --- Insert Ask Note Sheet at the top level ---
        //.sheet(isPresented: $isPresentingAskNoteSheet) {
        //    _askNoteSheetContent
        //}
        .fullScreenCover(isPresented: $showQuizSheet) {
            if let base = _paperBaseDir() {
                Inf6PaperQuizSheet(
                    paperTitle: pdfTitle,
                    paperKey: _quizPaperKey,
                    baseDir: base,
                    genLangRaw: genLangRaw,
                    pageNotesProvider: { _currentQuizPageNotes() },
                    mathCardsProvider: { _currentQuizMathCardSources() },
                    askModel: { prompt in
                        let targetLang = (genLangRaw == "en") ? "en" : "ja"
                        let promptRef = (targetLang == "en")
                            ? Inf6PromptCatalog.quizPromptBridgeEn
                            : Inf6PromptCatalog.quizPromptBridgeJa
                        let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                            ref: promptRef,
                            variables: ["task_prompt": prompt]
                        )
                        return try await Inf6LibraryView.askOpenAIText(
                            systemInstruction: rendered.systemInstruction,
                            userPrompt: rendered.userPrompt,
                            lang: targetLang
                        )
                    }
                )
            } else {
                NavigationView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Inf6Lang.text("演習を開けません", "Cannot open exercise"))
                            .font(.headline)

                        Text(Inf6Lang.text(
                            "論文フォルダが解決できないため、演習を開始できません。論文の保存先が利用可能であることをご確認ください。",
                            "The paper folder could not be resolved, so the exercise cannot start. Ensure the paper storage location is available."
                        ))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(Inf6Lang.text("閉じる", "Close")) {
                                showQuizSheet = false
                }
            }
        }
        .alert(
            Inf6Lang.text("演習自動生成に失敗", "Automatic exercise generation failed"),
            isPresented: Binding(
                get: { _autoQuizLastError != nil },
                set: { presenting in
                    if !presenting { _autoQuizLastError = nil }
                }
            )
        ) {
            Button(Inf6Lang.text("OK", "OK"), role: .cancel) {
                _autoQuizLastError = nil
            }
        } message: {
            Text(_autoQuizLastError ?? "")
        }
    }
}
        }
        //.overlay {
        //    _assetsPipelineFinishedPopup
        //}
        .overlay(alignment: .bottomTrailing) {
            _explainPromptPanelOverlay_UI()
                .environment(\.colorScheme, .light)
        }
        .onAppear {
            if abstractNote.text != explanation {
                abstractNote.text = explanation
                abstractNote.rtf = nil
            }

            _handlePDFChanged(to: url)
            _restoreAssetsPipelineIndicatorFromDisk()

            #if os(iOS)
            let idiom = UIDevice.current.userInterfaceIdiom
            let isPhoneUI: Bool = (idiom == .phone)
            let isDesignedForiPadOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac || (idiom == .mac)
            #else
            let isPhoneUI: Bool = false
            let isDesignedForiPadOnMac: Bool = false
            #endif

            // iPhone: do not restore persisted zoom (often comes from other form factors and looks oversized).
            // Use the neutral baseline and let the user pinch as needed.
            if isPhoneUI && !isDesignedForiPadOnMac {
                zoom = _inf6SafeZoomForLayout(1.0)
            } else {
                let sz = storedZoom.isFinite ? storedZoom : 1.0
                zoom = _inf6SafeZoomForLayout(CGFloat(sz))
            }
        }
        .onChange(of: url) { _, newURL in
            _handlePDFChanged(to: newURL)
            _restoreAssetsPipelineIndicatorFromDisk()
        }
        .onChange(of: selectedPage.wrappedValue) { _, newIdx in
            _handleSelectedPageChange(newIdx)
        }
        .onChange(of: showDetailPane) { _, isShowing in
            if !isShowing {
                isShowingExplainActionsPanel = false
            }
        }
        .onChange(of: pdfSelectedText) { _, newVal in
            _rememberLatestSelectionText()
            // Fix (Issue 1): keep panel selection live while panel is open.
            if isShowingExplainActionsPanel {
                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    _explainPanelSelectionText = trimmed
                }
            }
        }
        .onChange(of: detailSelectedText) { _, _ in
            _rememberLatestSelectionText()
        }
        .onChange(of: _miniCardSelectedText) { _, _ in
            _rememberLatestSelectionText()
        }
        .onChange(of: isShowingExplainActionsPanel) { _, isShowing in
            if !isShowing {
                _explainPanelSelectionText = ""
            }
        }
        .onChange(of: isShowingExplainPromptPanel) { _, isShowing in
            if isShowing {
                isShowingExplainActionsPanel = false
            }
        }
        .onChange(of: zoom) { _, newVal in
            let clamped = _inf6SafeZoomForLayout(newVal)
            if clamped != newVal {
                zoom = clamped
                return
            }

            guard let v = pdfViewRef else {
                print("[InlinePDFPagesView] zoom changed before PDFView is ready; not persisting yet.")
                return
            }

            #if os(iOS)
            let idiom = UIDevice.current.userInterfaceIdiom
            let isPhoneUI: Bool = (idiom == .phone)
            let isDesignedForiPadOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac || (idiom == .mac)
            if isPhoneUI && !isDesignedForiPadOnMac {
                // iPhone: keep session zoom changes, but do not persist them.
                Task { @MainActor in
                    _enableAndFlashPDFScrollIndicators(v)
                }
                return
            }
            #endif

            storedZoom = Double(clamped)
            Task { @MainActor in
                _enableAndFlashPDFScrollIndicators(v)
            }
        }
    }
}
