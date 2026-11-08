import Foundation

/// Public curriculum choices only; never includes Studentweb data.
struct StudyPlanSelection: Codable, Equatable, Sendable {
    var programmeCode: String
    var admissionYear: Int
    var studyYear: Int? = nil
    var term: String? = nil
    var branchPath: [String]? = nil
}

/// Public curriculum data only. This catalog never contains Studentweb records.
struct StudyPlanCatalog: Codable, Sendable {
    struct Course: Codable, Sendable { let code: String; let version: String?; let name: String; let credits: Double?; let kind: String }
    struct Choice: Codable, Sendable { let code: String; let name: String?; let description: String? }
    struct Entry: Codable, Sendable { let courseID: String; let choiceID: String }
    struct Group: Codable, Sendable {
        let code: String?; let name: String?; let description: String?; let relativePeriod: Int
        let deadline: String?; let entries: [Entry]
    }
    struct BranchChoice: Codable, Sendable {
        let code: String?; let name: String?; let description: String?; let deadline: String?; let nodeIDs: [String]
    }
    struct Node: Codable, Sendable {
        let code: String?; let name: String?; let directionCode: String?; let designation: String?
        let groupIDs: [String]; let choices: [BranchChoice]
    }
    struct Period: Codable, Sendable {
        let number: Int; let studyYear: Int; let term: String; let calendarYear: Int; let nodeID: String
    }
    struct Plan: Codable, Sendable {
        let programmeCode: String; let admissionYear: Int; let name: String; let studyYears: Int; let startTerm: String
        let sourceURL: String; let resourceURL: String; let sourceUpdatedAt: String?; let sha256: String
        let publishedAcademicYears: [Int]; let periods: [Period]
    }
    let schemaVersion: Int
    let fetchedAt: String
    let courses: [String: Course]
    let choices: [String: Choice]
    let groups: [String: Group]
    let nodes: [String: Node]
    let plans: [String: Plan]
    let defaultAdmissionYears: [String: Int]?
}

struct StudyPlanIndex: Sendable {
    struct Placement: Codable, Sendable {
        let planID: String; let studyYear: Int; let period: Int; let term: String; let calendarYear: Int
        let branch: [String]; let groupID: String; let courseID: String; let choiceID: String
    }
    let catalog: StudyPlanCatalog
    private(set) var byCourse: [String: [Placement]] = [:]
    private(set) var byPlanYear: [String: [Placement]] = [:]
    private(set) var byPlan: [String: [Placement]] = [:]

    struct BranchOption: Sendable {
        let path: [String]
        let name: String
    }
    var programmeCodes: [String] { Set(catalog.plans.values.map(\.programmeCode)).sorted() }
    func admissionYears(_ code: String) -> [Int] {
        catalog.plans.values.filter { $0.programmeCode == code }.map(\.admissionYear).sorted(by: >)
    }
    func defaultSelection(_ code: String) -> StudyPlanSelection {
        let years = admissionYears(code), preferred = catalog.defaultAdmissionYears?[code] ?? 2023
        return StudyPlanSelection(programmeCode: code, admissionYear: years.contains(preferred) ? preferred : (years.first ?? 2023))
    }
    private var defaultPlanIDs: [String] {
        programmeCodes.map { "\($0):\(defaultSelection($0).admissionYear)" }.sorted()
    }
    private func branchKey(_ node: StudyPlanCatalog.Node) -> String? { node.directionCode ?? node.code }
    func branches(_ planID: String) -> [BranchOption] {
        var result: [[String]: BranchOption] = [:]
        func visit(_ id: String, path: [String], names: [String]) {
            let node = catalog.nodes[id]!
            var path = path, names = names
            if let key = branchKey(node) {
                path.append(key); names.append(node.name ?? key)
                result[path] = BranchOption(path: path, name: names.joined(separator: " / "))
            }
            for choice in node.choices { for child in choice.nodeIDs { visit(child, path: path, names: names) } }
        }
        for period in catalog.plans[planID]?.periods ?? [] { visit(period.nodeID, path: [], names: []) }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func selectedPeriods(_ plan: StudyPlanCatalog.Plan, selection: StudyPlanSelection) -> [Int] {
        (1...(plan.studyYears * 2)).filter { number in
            let term = (number % 2 == 1) == (plan.startTerm == "autumn") ? "autumn" : "spring"
            return (selection.studyYear == nil || (number + 1) / 2 == selection.studyYear) &&
                (selection.term == nil || term == selection.term)
        }
    }

    static let instructions = """
    Use the attached NTNU study-plan reference for programme placement, study year, semester and choice rules. The retrieved-plans catalogue is a small index of available degrees at the selected, locked admission years. It is not enrolment evidence. results contains only the model-requested local lookups. For a comparison of exam X in one degree and exam Y in another, start with which exam to take and why, use passedCourseCodes as completed background when supplied, and relate each option to its actual year and branch placement. Distinguish filling a foundation gap from advancing in a specialisation; compare relevant requirements and preparation rather than automatically preferring the earlier-year course. Do not replace the requested comparison with all available degrees or courses. A required course (O) is required within its branch; never combine alternative branches into one set of requirements. VA, VB and V are elective statuses; M1A/M2A are group minimums, not a requirement to complete every listed course. Keep group descriptions and non-course requirements separate from exam courses. Course lookups show only the requested placements. Year lookups preserve common and ancestor requirements for the retrieved branch. These are retrieval choices, not confirmation of the student’s chosen specialisation. Course definitions are shared; choice rules belong to group entries. Missing periods are unpublished, not empty or optional. An unmatched course code was not found in this cohort snapshot; it does not prove ineligibility or equivalence. Omitted records are outside this lookup, not absent from the degree. Never substitute another admission year or assume old chat claims override the current cohorts or passed-course list. Do not infer prerequisites, eligibility, equivalences or degree completion percentages from placements and passes alone. If a decisive rule, study direction or preparation level is missing, give a conditional recommendation and ask a focused question. Use sourceURL when citing requirements.
    """

    // Decode and index once. Packaged apps use the same public JSON distributed
    // with the native resources; command-line builds resolve the repository copy.
    static let bundled: Result<StudyPlanIndex, Error> = Result {
        let resource = Bundle.main.resourceURL?.appendingPathComponent("NativeResources/ntnu-study-plans.json")
        if let resource, FileManager.default.fileExists(atPath: resource.path) {
            return try StudyPlanIndex(data: Data(contentsOf: resource))
        }
        if Bundle.main.bundleURL.pathExtension != "app" {
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { root.deleteLastPathComponent() }
            return try StudyPlanIndex(data: Data(contentsOf: root.appendingPathComponent("dist/native-resources/ntnu-study-plans.json")))
        }
        throw StudyError.message("The public degree-plan catalog is missing. Rebuild or update Scholia before requesting degree advice.")
    }

    init(data: Data) throws {
        guard data.count <= 20_000_000 else { throw Self.invalid }
        let catalog = try JSONDecoder().decode(StudyPlanCatalog.self, from: data)
        guard catalog.schemaVersion == 1, catalog.plans.count <= 200 else { throw Self.invalid }
        self.catalog = catalog
        var total = 0
        func walk(_ id: String, planID: String, period: StudyPlanCatalog.Period,
            branch: [String], ancestors: Set<String>) throws -> [Placement] {
            guard let node = catalog.nodes[id], !ancestors.contains(id), ancestors.count <= 12 else { throw Self.invalid }
            let branch = (node.directionCode ?? node.code) == nil ? branch : branch + [id]
            var result: [Placement] = []
            for groupID in node.groupIDs {
                guard let group = catalog.groups[groupID] else { throw Self.invalid }
                for entry in group.entries {
                    total += 1
                    guard catalog.courses[entry.courseID] != nil, catalog.choices[entry.choiceID] != nil,
                        total <= 100_000 else { throw Self.invalid }
                    result.append(Placement(planID: planID, studyYear: period.studyYear, period: period.number,
                        term: period.term, calendarYear: period.calendarYear, branch: branch, groupID: groupID,
                        courseID: entry.courseID, choiceID: entry.choiceID))
                }
            }
            for choice in node.choices {
                for child in choice.nodeIDs {
                    result += try walk(child, planID: planID, period: period, branch: branch, ancestors: ancestors.union([id]))
                }
            }
            return result
        }
        for id in catalog.plans.keys.sorted() {
            let plan = catalog.plans[id]!
            guard (1...10).contains(plan.studyYears), !plan.periods.isEmpty else { throw Self.invalid }
            byPlan[id] = []
            for period in plan.periods {
                guard (1...(plan.studyYears * 2)).contains(period.number), period.studyYear == (period.number + 1) / 2,
                    ["autumn", "spring"].contains(period.term) else { throw Self.invalid }
                for hit in try walk(period.nodeID, planID: id, period: period, branch: [], ancestors: []) {
                    byPlan[id, default: []].append(hit)
                    byPlanYear["\(id):\(hit.studyYear)", default: []].append(hit)
                    byCourse[catalog.courses[hit.courseID]!.code, default: []].append(hit)
                }
            }
        }
    }

    private static var invalid: StudyError { .message("The public degree-plan catalog could not be read safely.") }
    func course(_ code: String) -> [Placement] { byCourse[code.uppercased()] ?? [] }
    func year(programmeCode: String, admissionYear: Int, studyYear: Int, term: String? = nil) -> [Placement] {
        let rows = byPlanYear["\(programmeCode.uppercased()):\(admissionYear):\(studyYear)"] ?? []
        return term.map { value in rows.filter { $0.term == value } } ?? rows
    }
    func missingPeriods(_ plan: StudyPlanCatalog.Plan) -> [Int] {
        let published = Set(plan.periods.map(\.number))
        return (1...(plan.studyYears * 2)).filter { !published.contains($0) }
    }

    func summary(_ id: String) -> [String: Any] {
        let plan = catalog.plans[id]!
        return ["planID": id, "programmeCode": plan.programmeCode, "admissionYear": plan.admissionYear,
            "name": plan.name, "studyYears": plan.studyYears, "sourceURL": plan.sourceURL,
            "sourceUpdatedAt": plan.sourceUpdatedAt ?? "", "fetchedAt": catalog.fetchedAt,
            "publishedPeriods": plan.periods.map(\.number), "missingPeriods": missingPeriods(plan)]
    }

    func selectedReference(_ selections: [StudyPlanSelection]) throws -> String? {
        guard selections.count <= 8 else { throw Self.invalidSelection }
        if selections.isEmpty { return nil }
        var seen = Set<String>(), plans: [[String: Any]] = [], nodes: [String: Any] = [:]
        var groups = Set<String>(), courses = Set<String>(), choices = Set<String>()
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        for selection in selections {
            let id = "\(selection.programmeCode):\(selection.admissionYear)", path = selection.branchPath ?? []
            guard let plan = catalog.plans[id], seen.insert(selection.programmeCode).inserted,
                selection.studyYear.map({ (1...plan.studyYears).contains($0) }) ?? true,
                selection.term.map({ ["autumn", "spring"].contains($0) }) ?? true else { throw Self.invalidSelection }
            let options = branches(id), branch = options.first { $0.path == path }
            guard path.isEmpty || branch != nil else { throw Self.invalidSelection }
            func visit(_ nodeID: String, route: [String] = []) throws -> String? {
                let node = catalog.nodes[nodeID]!
                let route = branchKey(node).map { route + [$0] } ?? route
                guard path.isEmpty || zip(route, path).allSatisfy({ $0.0 == $0.1 }) else { return nil }
                let outputID = "\(id)/\(nodeID)/\(route.joined(separator: "/"))"
                if nodes[outputID] != nil { return outputID }
                var value = try object(node) as! [String: Any], filteredChoices: [[String: Any]] = []
                for choice in node.choices {
                    let children = try choice.nodeIDs.compactMap { try visit($0, route: route) }
                    if !children.isEmpty {
                        var value = try object(choice) as! [String: Any]; value["nodeIDs"] = children
                        filteredChoices.append(value)
                    }
                }
                value["choices"] = filteredChoices; nodes[outputID] = value
                for groupID in node.groupIDs {
                    groups.insert(groupID)
                    for entry in catalog.groups[groupID]!.entries { courses.insert(entry.courseID); choices.insert(entry.choiceID) }
                }
                return outputID
            }
            let selected = selectedPeriods(plan, selection: selection)
            var periods: [[String: Any]] = []
            for period in plan.periods where selected.contains(period.number) {
                if let nodeID = try visit(period.nodeID) {
                    var value = try object(period) as! [String: Any]; value["nodeID"] = nodeID; periods.append(value)
                }
            }
            var value = summary(id), chosen = try object(selection) as! [String: Any]
            chosen["branchPath"] = path; chosen["specialisation"] = branch.map { $0.name as Any } ?? NSNull()
            value["selection"] = chosen; value["selectedPeriods"] = selected; value["periods"] = periods; plans.append(value)
        }
        return try encodeReference(["scope": "selected-plans", "plans": plans, "nodes": nodes,
            "groups": try object(catalog.groups.filter { groups.contains($0.key) }),
            "courses": try object(catalog.courses.filter { courses.contains($0.key) }),
            "choices": try object(catalog.choices.filter { choices.contains($0.key) })])
    }
    private static var invalidSelection: StudyError {
        .message("Choose an available admission year, study year, semester and specialisation.")
    }

    func reference(question: String, history: [StudyExamAdviceMessage] = [], extraCourseCodes: [String] = [],
        selections: [StudyPlanSelection]? = nil) throws -> String? {
        if let selections { return try selectedReference(selections) }
        let text = ([question] + history.filter { $0.role == .user }.map(\.content)).joined(separator: "\n").uppercased()
        let tokens = Set(text.components(separatedBy: .alphanumerics.inverted))
        let currentTokens = Set(question.uppercased().components(separatedBy: .alphanumerics.inverted))
        let currentPlans = defaultPlanIDs.filter { currentTokens.contains(catalog.plans[$0]!.programmeCode) }
        let selected = !currentPlans.isEmpty ? currentPlans : defaultPlanIDs.filter { tokens.contains(catalog.plans[$0]!.programmeCode) }
        func codes(in value: String) -> [String] {
            let value = value.uppercased()
            let re = try! NSRegularExpression(pattern: #"\b[A-ZÆØÅ]{2,8}\d{3,6}[A-Z]?\b"#)
            return Set(re.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            }).sorted()
        }
        let currentCodes = codes(in: question)
        let codes = !currentCodes.isEmpty ? currentCodes : !selected.isEmpty ? [] : codes(in: text)
        guard !selected.isEmpty || codes.contains(where: { byCourse[$0] != nil }) else { return nil }
        let planIDs = selected.isEmpty ? defaultPlanIDs : selected
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        var output: [String: Any]
        if !codes.isEmpty {
            let wanted = Set(codes + extraCourseCodes).sorted()
            let matches = wanted.flatMap { course($0).filter { planIDs.contains($0.planID) } }
            let courseIDs = Set(matches.map(\.courseID)), choiceIDs = Set(matches.map(\.choiceID))
            let groupIDs = Set(matches.map(\.groupID)), branchIDs = Set(matches.flatMap(\.branch))
            var groups: [String: Any] = [:], branches: [String: Any] = [:]
            for id in groupIDs {
                let group = catalog.groups[id]!
                groups[id] = ["code": group.code ?? "", "name": group.name ?? "",
                    "description": group.description ?? "", "totalEntries": group.entries.count]
            }
            for id in branchIDs {
                let node = catalog.nodes[id]!
                branches[id] = ["code": node.code ?? "", "name": node.name ?? "",
                    "directionCode": node.directionCode ?? "", "designation": node.designation ?? ""]
            }
            output = ["scope": "course-lookup", "plans": planIDs.map(summary), "requestedCourseCodes": codes,
                "matches": try object(matches), "courses": try object(catalog.courses.filter { courseIDs.contains($0.key) }),
                "choices": try object(catalog.choices.filter { choiceIDs.contains($0.key) }), "groups": groups, "branches": branches]
        } else {
            var nodes = Set<String>(), groups = Set<String>(), courses = Set<String>(), choices = Set<String>()
            func visit(_ id: String) {
                guard nodes.insert(id).inserted else { return }
                let node = catalog.nodes[id]!
                for groupID in node.groupIDs {
                    groups.insert(groupID)
                    for entry in catalog.groups[groupID]!.entries { courses.insert(entry.courseID); choices.insert(entry.choiceID) }
                }
                for choice in node.choices { choice.nodeIDs.forEach(visit) }
            }
            for id in planIDs { catalog.plans[id]!.periods.forEach { visit($0.nodeID) } }
            let plans = try planIDs.map { id -> [String: Any] in
                var plan = summary(id); plan["periods"] = try object(catalog.plans[id]!.periods); return plan
            }
            output = ["scope": "full-plans", "plans": plans, "nodes": try object(catalog.nodes.filter { nodes.contains($0.key) }),
                "groups": try object(catalog.groups.filter { groups.contains($0.key) }),
                "courses": try object(catalog.courses.filter { courses.contains($0.key) }),
                "choices": try object(catalog.choices.filter { choices.contains($0.key) })]
        }
        return try encodeReference(output)
    }

    private func encodeReference(_ output: [String: Any]) throws -> String {
        let value = String(decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), as: UTF8.self)
        guard value.utf16.count <= MessageAttachmentIngestion.maximumExtractedUTF16Units else {
            throw StudyError.message("The degree-plan reference is too large. Ask about a specific programme or course.")
        }
        return value
    }
}
