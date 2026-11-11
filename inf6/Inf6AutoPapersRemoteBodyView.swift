//  Inf6AutoPapersRemoteBodyView.swift
//  inf6
//
//  Lightweight ExploreCourses (remote) body view used from Inf6AutoPapersView.
//  「スクール選択＋シラバス一覧表示」のみに責務を絞った実装。
//  PDF インポートや Inf6LibraryView の状態には依存しません。
//

import SwiftUI

struct Inf6AutoPapersRemoteBodyView: View {
    let branding: Inf6CompassBranding

    @Binding var selectedSource: Inf6SyllabusSource
    @Binding var selectedSyllabusRoot: Inf6SyllabusRoot
    @Binding var selectedDepartmentCode: String

    @Binding var syllabi: [Inf6StanfordSyllabus]
    @Binding var schools: [ECSchool]
    @Binding var filtered: [Inf6StanfordSyllabus]
    @Binding var searchText: String

    @Binding var statusMessage: String
    @Binding var translatedTitles: [String: String]

    /// Inf6AutoPapersView から注入されるラベル解決クロージャ
    let selectedDepartmentLabel: () -> String
    let displayTitle: (Inf6StanfordSyllabus) -> String
    let onReload: (_ forceNetwork: Bool) -> Void
    let onApplyFilter: () -> Void

    var body: some View {
        // Top controls (pinned above the list). Avoid segmented controls.
        let sourcePickerTitle = Inf6Lang.text("ソース", "Source")
        let categoryPickerTitle = Inf6Lang.text("分類", "Category")
        let syllabusListTitle = Inf6Lang.text("シラバス一覧", "Syllabi")
        let syllabusListEmptyText = Inf6Lang.text(
            "スクールを選択してから上部の更新ボタンでシラバスを取得してください。",
            "Select a school first, then tap Reload in the top bar to fetch syllabi."
        )

        // ExploreCourses 用: スクール / 学科の選択
        let departments: [(code: String, label: String)] = schools.flatMap { school in
            school.departments.map { dept in
                (dept.code, "\(school.displayName) / \(dept.displayName)")
            }
        }

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Picker(sourcePickerTitle, selection: $selectedSource) {
                        ForEach(Inf6SyllabusSource.allCases, id: \.self) { src in
                            Text(src.displayLabel()).tag(src)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedSource) { _, newSrc in
                        if newSrc == .localYAML {
                            selectedDepartmentCode = ""
                        }
                        onReload(false)
                    }

                    Picker(categoryPickerTitle, selection: $selectedSyllabusRoot) {
                        ForEach(Inf6SyllabusRoot.allCases) { root in
                            Text(root.displayLabel()).tag(root)
                        }
                    }
                    .pickerStyle(.menu)
                    .modifier(_Inf6OnChangeCompat(value: selectedSyllabusRoot) {
                        onReload(false)
                    })

                    if selectedSource == .explorecourses {
                        Picker(Inf6Lang.text("スクール", "School"), selection: $selectedDepartmentCode) {
                            Text(Inf6Lang.text("未選択", "Not selected"))
                                .tag("")
                            ForEach(departments, id: \.code) { item in
                                Text(item.label).tag(item.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .modifier(_Inf6OnChangeCompat(value: selectedDepartmentCode) {
                            onReload(false)
                        })
                    }

                    Spacer()

                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .background(.ultraThinMaterial)

            // Insert paper search section at the top of the List
            List {
                Section(header: Text(syllabusListTitle)) {
                    if syllabi.isEmpty {
                        Text(syllabusListEmptyText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { _, syllabus in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayTitle(syllabus))
                                    .font(.body)
                                    .lineLimit(2)
                                if !syllabus.detail.isEmpty {
                                    Text(syllabus.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
            #if os(iOS)
            .searchable(
                text: Binding(
                    get: { searchText },
                    set: { searchText = $0.localizedLowercase }
                ),
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(Inf6Lang.text("例: machine learning, PDF など", "e.g. machine learning, math"))
            )
#else
            .searchable(
                text: Binding(
                    get: { searchText },
                    set: { searchText = $0.localizedLowercase }
                ),
                prompt: Text(Inf6Lang.text("例: machine learning, PDF など", "e.g. machine learning, math"))
            )
#endif
            .onChange(of: searchText) { _, _ in
                onApplyFilter()
            }
        }
    }
}


struct _Inf6OnChangeCompat<T: Equatable>: ViewModifier {
    let value: T
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: value) { _, _ in
                action()
            }
        } else {
            content.onChange(of: value) { _ in
                action()
            }
        }
    }
}
