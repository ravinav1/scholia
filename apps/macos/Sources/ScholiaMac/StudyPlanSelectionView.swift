import SwiftUI

struct StudyPlanSelectionView: View {
    let index: StudyPlanIndex
    @Binding var selections: [StudyPlanSelection]?
    @State private var focusExpanded = false
    @State private var previousSelections: [StudyPlanSelection]?
    private var current: [StudyPlanSelection] { selections ?? index.programmeCodes.map(index.defaultSelection) }
    private func binding(_ code: String) -> Binding<StudyPlanSelection> {
        Binding(get: { current.first { $0.programmeCode == code } ?? index.defaultSelection(code) }, set: { value in
            var updated = current
            if let offset = updated.firstIndex(where: { $0.programmeCode == code }) { updated[offset] = value }
            selections = updated
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use degree plans for advice", isOn: Binding(get: { selections?.isEmpty != true }, set: { enabled in
                if enabled { selections = previousSelections ?? index.programmeCodes.map(index.defaultSelection) }
                else { previousSelections = current; selections = [] }
            })).accessibilityIdentifier("degree-enabled")
            if !current.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(current, id: \.programmeCode) { value in
                        Picker("\(value.programmeCode) admission", selection: Binding(get: { binding(value.programmeCode).wrappedValue.admissionYear }, set: { year in
                            var selected = binding(value.programmeCode).wrappedValue
                            selected.admissionYear = year; selected.branchPath = nil
                            binding(value.programmeCode).wrappedValue = selected
                        })) {
                            ForEach(index.admissionYears(value.programmeCode), id: \.self) { Text(String($0)).tag($0) }
                        }.accessibilityIdentifier("degree-admission-\(value.programmeCode)")
                    }
                }
                Text("Scholia uses your question and passed courses to look up the relevant degree, study year and specialisation.")
                    .foregroundStyle(.secondary)
                DisclosureGroup("Optional study focus", isExpanded: $focusExpanded) {
                    ForEach(current, id: \.programmeCode) { value in
                        StudyPlanFocusRow(index: index, selection: binding(value.programmeCode))
                    }
                }
            }
        }.font(.system(size: 11)).pickerStyle(.menu)
    }
}

private struct StudyPlanFocusRow: View {
    let index: StudyPlanIndex
    @Binding var selection: StudyPlanSelection
    var body: some View {
        let id = "\(selection.programmeCode):\(selection.admissionYear)"
        if let plan = index.catalog.plans[id] {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(selection.programmeCode) · \(plan.name)").fontWeight(.medium)
                Picker("Study year", selection: Binding(get: { selection.studyYear ?? 0 }, set: { selection.studyYear = $0 == 0 ? nil : $0 })) {
                    Text("Let Scholia choose").tag(0)
                    ForEach(1...plan.studyYears, id: \.self) { Text("Year \($0)").tag($0) }
                }.accessibilityIdentifier("degree-year-\(selection.programmeCode)")
                Picker("Semester", selection: Binding(get: { selection.term ?? "auto" }, set: { selection.term = $0 == "auto" ? nil : $0 })) {
                    Text("Let Scholia choose").tag("auto")
                    Text("Autumn").tag("autumn")
                    Text("Spring").tag("spring")
                }.accessibilityIdentifier("degree-term-\(selection.programmeCode)")
                Picker("Specialisation / profile", selection: Binding(get: { selection.branchPath ?? [] }, set: { selection.branchPath = $0 })) {
                    Text("Let Scholia choose").tag([String]())
                    ForEach(index.branches(id), id: \.path) { option in Text(option.name).tag(option.path) }
                }.accessibilityIdentifier("degree-branch-\(selection.programmeCode)")
                Text("A focus guides the lookup; Scholia can still check relevant foundations in other years.").foregroundStyle(.secondary)
                if let url = URL(string: plan.sourceURL) { Link("View this admission-year plan at NTNU", destination: url) }
            }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
