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
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "worktree.baseBranch.label", defaultValue: "Base:"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        TextField(defaultBranch, text: $baseBranch)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    if !detectedBranches.isEmpty && !baseBranch.isEmpty
                        && !detectedBranches.contains(baseBranch) {
                        let filtered = detectedBranches.filter {
                            $0.localizedCaseInsensitiveContains(baseBranch)
                        }
                        if !filtered.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(filtered.prefix(20), id: \.self) { branch in
                                        Text(branch)
                                            .font(.system(size: 12, design: .monospaced))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                baseBranch = branch
                                            }
                                    }
                                }
                            }
                            .frame(maxHeight: 120)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
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
            if useWorktree {
                validateRepo(newPath)
            }
        }
        .onChange(of: useWorktree) { _, isWorktree in
            if isWorktree {
                validateRepo(repoPath)
            } else {
                // Switching to Regular mode: restore original directory if available
                if let dir = initialDirectory, !dir.isEmpty, dir != NSHomeDirectory() {
                    repoPath = dir
                }
            }
        }
        .onAppear {
            loadRecentRepos()
            if let dir = initialDirectory, !dir.isEmpty, dir != NSHomeDirectory() {
                // Initial mode is always Worktree, so auto-detect git root.
                DispatchQueue.global(qos: .userInitiated).async {
                    let root = Self.findMainRepoRoot(from: dir)
                    DispatchQueue.main.async {
                        repoPath = (root != nil && !root!.isEmpty) ? root! : dir
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

        // Present as a child sheet of the WorktreeCreationView's host window.
        // Calling `panel.runModal()` from inside a SwiftUI `.sheet { }` action
        // creates a nested AppKit modal session on top of the SwiftUI modal,
        // which makes the panel's key-window state unreliable: clicks get
        // swallowed and navigation appears broken. `beginSheetModal(for:)`
        // attaches the panel as a sheet of the active window so AppKit can
        // route mouse/keyboard events properly.
        if let parent = NSApp.keyWindow {
            panel.beginSheetModal(for: parent) { response in
                if response == .OK, let url = panel.url {
                    repoPath = url.path
                }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
        }
    }

    private func validateRepo(_ path: String) {
        guard !path.isEmpty else {
            isValidRepo = false
            detectedBranches = []
            return
        }

        // Validate and canonicalize to the main repo root on a background thread.
        // Using findMainRepoRoot (--git-common-dir) instead of --show-toplevel
        // prevents nested worktree creation when the user types a worktree path.
        DispatchQueue.global(qos: .userInitiated).async {
            let mainRoot = Self.findMainRepoRoot(from: path)
            DispatchQueue.main.async {
                // Discard stale result if repoPath changed while async was in flight
                guard repoPath == path || repoPath == mainRoot else { return }
                if let mainRoot {
                    isValidRepo = true
                    // Canonicalize to main repo root to prevent nested worktrees
                    if repoPath != mainRoot {
                        repoPath = mainRoot
                    }
                    detectBranches(mainRoot)
                } else {
                    isValidRepo = false
                    detectedBranches = []
                }
            }
        }
    }

    private func detectBranches(_ forRepoPath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["branch", "-a", "--format=%(refname:short)"]
            process.currentDirectoryURL = URL(fileURLWithPath: forRepoPath)
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
                        // Discard stale result if repo changed while async was in flight
                        guard repoPath == forRepoPath else { return }
                        detectedBranches = branches
                        // Only auto-fill baseBranch if empty or no longer valid for this repo
                        let needsAutoFill = baseBranch.isEmpty || !branches.contains(baseBranch)
                        if let mainBranch = branches.first(where: { $0 == "main" || $0 == "master" }) {
                            defaultBranch = mainBranch
                            if needsAutoFill {
                                baseBranch = mainBranch
                            }
                        } else if let first = branches.first {
                            defaultBranch = first
                            if needsAutoFill {
                                baseBranch = first
                            }
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
