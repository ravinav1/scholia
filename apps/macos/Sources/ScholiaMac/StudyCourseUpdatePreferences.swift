import SwiftUI

struct StudyCourseUpdatePreferences: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var showsStatus = false
    @State private var updateCourseID: UUID?

    var body: some View {
        let courses = workspace.canvasUpdatableCourses
        let selectedCourse = courses.first { $0.id == updateCourseID }
            ?? courses.first { $0.id == workspace.library.selectedCourseID } ?? courses.first
        Toggle("Automatically update math wiki", isOn: $workspace.automaticallyUpdateMathWiki)
        Text("Check math wiki pages every two minutes while the workspace is open, even when Canvas needs reconnecting. Recheck linked files every five minutes, or sooner when their course page changes. Only new or changed materials are downloaded.")
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle("Automatically update course content", isOn: $workspace.automaticallyUpdateCanvasContent)
        Text("Every five minutes while the workspace is open, check current-semester courses, favorites and the course you open. Fetch new or changed files, pages, assignments and the syllabus. Saved local edits are kept separately.")
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("Scholia learns when each course usually publishes material and adds occasional checks at those times. Extra checks are limited to two per course and source, and eight across the workspace, in 24 hours. Regular checks continue; repeated failures slow down retries.")
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let selectedCourse {
            HStack {
                Picker("Update a course", selection: Binding(get: { selectedCourse.id }, set: { updateCourseID = $0 })) {
                    ForEach(courses) { course in
                        Text(course.code.isEmpty ? course.displayName : "\(course.code) · \(course.displayName)").tag(course.id)
                    }
                }.pickerStyle(.menu)
                StudyCourseUpdateButton(workspace: workspace, courseID: selectedCourse.id).fixedSize()
            }
            Text(workspace.canvasNeedsAuthentication
                ? "Reconnect Canvas to update course content."
                : "Manual updates work with automatic updates off. If downloads are running, the course update is queued until they finish.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showsStatus, let status = workspace.canvasStatus {
                HStack(alignment: .top) {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if workspace.canvasBusy {
                        Spacer()
                        Button("Stop", action: workspace.cancelCanvas).font(.caption)
                    }
                }
            }
        }
    }
}

struct StudyCourseUpdateButton: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var courseID: UUID

    var body: some View {
        Button(workspace.canvasCourseUpdateTitle(courseID), systemImage: "arrow.clockwise") {
            workspace.updateCanvasCourseContent(courseIDs: [courseID])
        }.disabled(!workspace.canUpdateCanvasCourseContent(courseID))
            .help("Check files, pages, assignments and the syllabus, then download new or changed content. Local edits are preserved.")
    }
}
