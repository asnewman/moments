import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.modifiedAt, order: .reverse) private var projects: [Project]
    @State private var showingNewProjectAlert = false
    @State private var newProjectName = ""
    @State private var projectToDelete: Project?
    @State private var showingDeleteConfirmation = false
    @State private var showingWelcome = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    emptyStateView
                } else {
                    projectList
                }
            }
            .navigationTitle("Moments")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        openFeedbackEmail()
                    } label: {
                        Image(systemName: "bubble.left")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newProjectName = ""
                        showingNewProjectAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Project", isPresented: $showingNewProjectAlert) {
                TextField("Project Name", text: $newProjectName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    createProject()
                }
            } message: {
                Text("Enter a name for your new project")
            }
            .alert("Delete Project?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    projectToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let project = projectToDelete {
                        modelContext.delete(project)
                        projectToDelete = nil
                    }
                }
            } message: {
                if let project = projectToDelete {
                    Text("Are you sure you want to delete \"\(project.name)\"? This cannot be undone.")
                }
            }
            .alert("Welcome to Moments!", isPresented: $showingWelcome) {
                Button("Got it!") {
                    hasSeenWelcome = true
                }
            } message: {
                Text("Thank you so much for downloading Moments!\n\nThis app is built by a single developer, and I truly appreciate you giving it a try.\n\nIf you run into any bugs or have feedback, please tap the 💬 icon in the top left. I read every message!\n\nEnjoy combining your moments!")
            }
            .onAppear {
                if !hasSeenWelcome {
                    showingWelcome = true
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Projects")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Create a project to start combining videos")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                newProjectName = ""
                showingNewProjectAlert = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .padding()
                    .background(Color.themePrimary)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private var projectList: some View {
        List {
            ForEach(projects) { project in
                NavigationLink(value: project) {
                    ProjectRowView(project: project)
                }
            }
            .onDelete(perform: deleteProjects)
        }
        .navigationDestination(for: Project.self) { project in
            ProjectEditorView(project: project)
        }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: name.isEmpty ? "Untitled Project" : name)
        modelContext.insert(project)
    }

    private func deleteProjects(at offsets: IndexSet) {
        if let index = offsets.first {
            projectToDelete = projects[index]
            showingDeleteConfirmation = true
        }
    }
}

struct ProjectRowView: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)

            Text("\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ProjectListView()
        .modelContainer(for: Project.self, inMemory: true)
}
