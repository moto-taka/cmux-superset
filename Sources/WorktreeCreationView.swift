import SwiftUI
import AppKit

/// Sheet view for creating a new worktree workspace.
struct WorktreeCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Pre-filled from the current workspace's directory (auto-detects git root).
    var initialDirectory: String?
    let onCreateWorktree: (String, String, String?) -> Void  // repoPath, branchName, baseBranch
    let onOpenFolder: (String) -> Void  // open as regular workspace

    @State private var repoPath: String = ""
    @State private var branchName: String = ""
    @State private var baseBranch: String = ""
    @State private var useWorktree: Bool = true
    @State private var recentRepos: [String] = []
    @State private var isValidRepo: Bool = false
    @State private var detectedBranches: [String] = []
    @State private var defaultBranch: String = "main"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text(String(localized: "worktree.create.title", defaultValue: "New Workspace"))
                .font(.headline)

            // Mode toggle: regular workspace vs worktree
            Picker("", selection: $useWorktree) {
                Text(String(localized: "worktree.mode.regular", defaultValue: "Regular"))
                    .tag(false)
                Text(String(localized: "worktree.mode.worktree", defaultValue: "Worktree"))
                    .tag(true)
            }
            .pickerStyle(.segmented)

            // Repository path
            HStack {
                TextField(
                    String(localized: "worktree.repo.placeholder", defaultValue: "Repository path..."),
                    text: $repoPath
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))

                Button(String(localized: "worktree.repo.browse", defaultValue: "Browse...")) {
                    browseForRepo()
                }
            }

            if useWorktree {
                // Branch name
                TextField(
                    String(localized: "worktree.branch.placeholder", defaultValue: "New branch name..."),
                    text: $branchName
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

                // Base branch (optional)
                HStack {
                    Text(String(localized: "worktree.baseBranch.label", defaultValue: "Base:"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    if detectedBranches.isEmpty {
                        TextField(defaultBranch, text: $baseBranch)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    } else {
                        Picker("", selection: $baseBranch) {
                            ForEach(detectedBranches, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                    }
                }

                // Validation warning
                if !repoPath.isEmpty && !isValidRepo {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 11))
                        Text(String(localized: "worktree.error.notGitRepo", defaultValue: "Not a git repository"))
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
            }

            Divider()

            // Action buttons
            HStack {
                Button(String(localized: "worktree.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(useWorktree
                    ? String(localized: "worktree.create.button", defaultValue: "Create Worktree")
                    : String(localized: "worktree.open.button", defaultValue: "Open Folder")
                ) {
                    if useWorktree {
                        onCreateWorktree(repoPath, branchName, baseBranch.isEmpty ? nil : baseBranch)
                    } else {
                        onOpenFolder(repoPath)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    useWorktree
                        ? (repoPath.isEmpty || branchName.isEmpty || !isValidRepo)
                        : repoPath.isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: repoPath) { _, newPath in
            validateRepo(newPath)
        }
        .onAppear {
            loadRecentRepos()
            if let dir = initialDirectory, !dir.isEmpty, dir != NSHomeDirectory() {
                // Auto-detect the main git repo root from current workspace directory.
                // Use --git-common-dir instead of --show-toplevel because --show-toplevel
                // returns the worktree root (not the main repo) when run inside a worktree.
                DispatchQueue.global(qos: .userInitiated).async {
                    let root = Self.findMainRepoRoot(from: dir)
                    if let root, !root.isEmpty {
                        DispatchQueue.main.async {
                            repoPath = root
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private helpers

    private func browseForRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "worktree.browse.title", defaultValue: "Select Repository")
        panel.prompt = String(localized: "worktree.browse.prompt", defaultValue: "Select")

        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
        }
    }

    private func validateRepo(_ path: String) {
        guard !path.isEmpty else {
            isValidRepo = false
            detectedBranches = []
            return
        }

        // Run git rev-parse on a background thread to avoid blocking the UI.
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["rev-parse", "--show-toplevel"]
            process.currentDirectoryURL = URL(fileURLWithPath: path)
            process.standardOutput = Pipe()
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let valid = process.terminationStatus == 0

                DispatchQueue.main.async {
                    isValidRepo = valid
                    if valid {
                        detectBranches(path)
                    } else {
                        detectedBranches = []
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isValidRepo = false
                    detectedBranches = []
                }
            }
        }
    }

    private func detectBranches(_ repoPath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["branch", "-a", "--format=%(refname:short)"]
            process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let branches = output
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.contains("HEAD") }

                    DispatchQueue.main.async {
                        detectedBranches = branches
                        if let mainBranch = branches.first(where: { $0 == "main" || $0 == "master" }) {
                            baseBranch = mainBranch
                            defaultBranch = mainBranch
                        } else if let first = branches.first {
                            baseBranch = first
                            defaultBranch = first
                        }
                    }
                }
            } catch {}
        }
    }

    private func loadRecentRepos() {
        recentRepos = UserDefaults.standard.stringArray(forKey: "cmux.recentRepos") ?? []
    }

    /// Resolve the main repository root, even when called from inside a worktree.
    ///
    /// `git rev-parse --show-toplevel` returns the worktree root when run inside a
    /// worktree, which leads to nested worktree creation. Instead, use
    /// `--git-common-dir` which always points to the main repository's `.git`
    /// directory; its parent is the true repo root.
    private static func findMainRepoRoot(from directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--path-format=absolute", "--git-common-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let gitCommonDir = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !gitCommonDir.isEmpty else { return nil }

            // --git-common-dir returns the path to the main repo's .git directory.
            // The parent of .git is the repository root.
            let url = URL(fileURLWithPath: gitCommonDir)
            if url.lastPathComponent == ".git" {
                return url.deletingLastPathComponent().path
            }
            // Fallback: if the structure is unexpected, use the directory's parent.
            return url.deletingLastPathComponent().path
        } catch {
            return nil
        }
    }
}
