//
//  Inf6SyllabusTreeView.swift
//  inf6
//

import SwiftUI

struct Inf6SyllabusTreeView: View {

    let store: Inf6CorePaperStore
    @State private var expandedSection: String? = nil

    private var summary: [(def: Inf6SyllabusCoverageDefinition, papers: [Inf6CorePaper])] {
        do {
            return try store.coverageSummary().map { (def: $0.definition, papers: $0.papers) }
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }

    private var doneFraction: Double {
        guard store.totalCount > 0 else { return 0 }
        return Double(store.doneCount) / Double(store.totalCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            _header
            Divider().padding(.vertical, 8)
            LazyVStack(spacing: 0) {
                ForEach(Array(summary.enumerated()), id: \.element.def.syllabusSection) { i, row in
                    _row(def: row.def, papers: row.papers)
                    if i < summary.count - 1 { Divider().padding(.leading, 20) }
                }
            }
        }
    }

    // MARK: - Header

    private var _header: some View {
        HStack(spacing: 16) {
            _ring(doneFraction, size: 64, stroke: 7)
                .overlay(
                    Text("\(Int(doneFraction * 100))%")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold).monospacedDigit())
                        .foregroundStyle(_color(doneFraction))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(store.doneCount)")
                        .font(.largeTitle.bold().monospacedDigit())
                    Text("/ \(store.totalCount)")
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
                _breakdownBar.frame(height: 8).clipShape(Capsule())
                HStack(spacing: 12) {
                    _dot(.green);  Text(Inf6Lang.text("修了", "Done")).font(.footnote)
                    _dot(.orange); Text(Inf6Lang.text("学習中", "Reading")).font(.footnote).foregroundStyle(Color.secondary)
                    _dot(Color.gray.opacity(0.4)); Text(Inf6Lang.text("未着手", "Not yet")).font(.footnote).foregroundStyle(Color.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func _dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }

    private var _breakdownBar: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                let w = g.size.width
                let t = Double(max(1, store.totalCount))
                Color.green.frame(width: w * Double(store.doneCount) / t)
                Color.orange.frame(width: w * Double(store.readingCount) / t)
                Color.gray.opacity(0.2).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Section row

    @ViewBuilder
    private func _row(def: Inf6SyllabusCoverageDefinition, papers: [Inf6CorePaper]) -> some View {
        let done    = papers.filter { store.progress[$0.id]?.status == .done }.count
        let reading = papers.filter { store.progress[$0.id]?.status == .reading }.count
        let total   = papers.count
        let frac    = total > 0 ? Double(done) / Double(total) : 0
        let open    = expandedSection == def.syllabusSection

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.22)) {
                    expandedSection = open ? nil : def.syllabusSection
                }
            } label: {
                HStack(spacing: 14) {
                    // priority
                    Image(systemName: def.isHighPriority ? "star.fill" : "circle.fill")
                        .font(def.isHighPriority ? .footnote : .system(size: Inf6ApplicationSystemFont.scaledSize(7)))
                        .foregroundStyle(def.isHighPriority ? Color.orange : Color.gray.opacity(0.35))
                        .frame(width: 18)

                    // name
                    Text(def.syllabusSection)
                        .font(.body.weight(def.isHighPriority ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    // count
                    if total > 0 {
                        Text("\(done)/\(total)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(_color(frac))
                    }

                    // ring
                    if total > 0 {
                        _ring(frac, size: 36, stroke: 4)
                    }

                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if total > 0 {
                GeometryReader { g in
                    HStack(spacing: 0) {
                        let w = g.size.width
                        let t = Double(max(1, total))
                        Color.green.frame(width: w * Double(done) / t)
                        Color.orange.frame(width: w * Double(reading) / t)
                        Color.gray.opacity(0.15).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, open ? 0 : 16)
            }

            if open { _expanded(papers: papers).padding(.bottom, 6) }
        }
    }

    // MARK: - Expanded paper list

    @ViewBuilder
    private func _expanded(papers: [Inf6CorePaper]) -> some View {
        if papers.isEmpty {
            Text(Inf6Lang.text("論文未登録", "No papers"))
                .font(.body)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(papers) { p in
                    let st = store.progress[p.id]?.status ?? .notStarted
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(_statusColor(st))
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                            .padding(.leading, 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title)
                                .font(.body)
                                .foregroundStyle(Color.primary)
                                .lineLimit(3)
                            HStack(spacing: 5) {
                                ForEach(p.tags.prefix(3), id: \.self) { t in
                                    Text(t).font(.caption)
                                        .foregroundStyle(Color.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    if p.id != papers.last?.id { Divider().padding(.leading, 42) }
                }
            }
            .background(Color(.systemGroupedBackground).opacity(0.6))
        }
    }

    // MARK: - Helpers

    private func _ring(_ fraction: Double, size: CGFloat, stroke: CGFloat) -> some View {
        ZStack {
            Circle().stroke(_color(fraction).opacity(0.15), lineWidth: stroke)
            Circle().trim(from: 0, to: fraction)
                .stroke(_color(fraction), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: fraction)
        }
        .frame(width: size, height: size)
    }

    private func _color(_ f: Double) -> Color {
        f >= 0.8 ? .green : f >= 0.4 ? .orange : f > 0 ? .blue : .gray
    }

    private func _statusColor(_ s: Inf6CorePaperStatus) -> Color {
        switch s { case .done: .green; case .reading: .orange; case .notStarted: .gray.opacity(0.4) }
    }
}
