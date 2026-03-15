import Foundation
import Combine
import Bonsplit

/// The type of git diff to display.
enum DiffMode: String, CaseIterable, Sendable {
    case unstaged
    case staged
    case all

    var localizedTitle: String {
        switch self {
        case .unstaged:
            return String(localized: "diff.mode.unstaged", defaultValue: "Unstaged")
        case .staged:
            return String(localized: "diff.mode.staged", defaultValue: "Staged")
        case .all:
            return String(localized: "diff.mode.all", defaultValue: "All Changes")
        }
    }
}

/// A panel that displays git diffs for a repository using a WebView-based diff viewer.
@MainActor
final class DiffPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .diff

    /// Absolute path to the git repository root.
    let repoPath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Title shown in the tab bar.
    @Published private(set) var displayTitle: String = String(localized: "diff.defaultTitle", defaultValue: "Changes")

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "chevron.left.forwardslash.chevron.right" }

    /// Raw unified diff output from git.
    @Published private(set) var diffContent: String = ""

    /// Whether a git diff command is currently running.
    @Published private(set) var isLoading: Bool = false

    /// Whether a git mutation (commit/push/pull/stage) is currently running.
    @Published private(set) var isPerformingGitAction: Bool = false

    /// Last error message from a git mutation command.
    @Published var lastGitError: String?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// The current diff mode being displayed.
    @Published var currentMode: DiffMode = .unstaged

    private var isClosed: Bool = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(workspaceId: UUID, repoPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.repoPath = repoPath

        #if DEBUG
        dlog("diff.init panel=\(id.uuidString.prefix(5)) repo=\(repoPath)")
        #endif

        refreshDiff()
    }

    // MARK: - Panel protocol

    func focus() {
        // Diff panel is read-only; no first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        #if DEBUG
        dlog("diff.close panel=\(id.uuidString.prefix(5))")
        #endif
        isClosed = true
    }

    func triggerFlash() {
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Workspace

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    // MARK: - Diff loading

    /// Load unstaged changes (git diff).
    func refreshDiff() {
        #if DEBUG
        dlog("diff.refresh mode=unstaged panel=\(id.uuidString.prefix(5))")
        #endif
        currentMode = .unstaged
        runGitDiff(args: ["diff"])
    }

    /// Load staged changes (git diff --staged).
    func loadStagedDiff() {
        #if DEBUG
        dlog("diff.refresh mode=staged panel=\(id.uuidString.prefix(5))")
        #endif
        currentMode = .staged
        runGitDiff(args: ["diff", "--staged"])
    }

    /// Load all changes including staged and unstaged (git diff HEAD).
    func loadAllDiff() {
        #if DEBUG
        dlog("diff.refresh mode=all panel=\(id.uuidString.prefix(5))")
        #endif
        currentMode = .all
        runGitDiff(args: ["diff", "HEAD"])
    }

    /// Switch diff mode programmatically.
    func switchMode(_ mode: DiffMode) {
        switch mode {
        case .unstaged:
            refreshDiff()
        case .staged:
            loadStagedDiff()
        case .all:
            loadAllDiff()
        }
    }

    // MARK: - Git mutations

    /// Stage all changes (git add -A).
    func stageAll() {
        #if DEBUG
        dlog("diff.stageAll panel=\(id.uuidString.prefix(5))")
        #endif
        runGitAction(args: ["add", "-A"], label: "stageAll") { [weak self] in
            self?.switchMode(self?.currentMode ?? .unstaged)
        }
    }

    /// Commit staged changes with the given message.
    func commitChanges(message: String) {
        #if DEBUG
        dlog("diff.commit panel=\(id.uuidString.prefix(5)) msgLen=\(message.count)")
        #endif
        runGitAction(args: ["commit", "-m", message], label: "commit") { [weak self] in
            self?.switchMode(self?.currentMode ?? .unstaged)
        }
    }

    /// Push the current branch to origin.
    func pushChanges() {
        #if DEBUG
        dlog("diff.push panel=\(id.uuidString.prefix(5))")
        #endif
        detectCurrentBranch { [weak self] branch in
            DispatchQueue.main.async {
                guard let self, let branch else {
                    self?.lastGitError = String(localized: "diff.error.noBranch", defaultValue: "Could not detect current branch.")
                    self?.isPerformingGitAction = false
                    return
                }
                self.runGitAction(args: ["push", "origin", branch], label: "push") { [weak self] in
                    self?.switchMode(self?.currentMode ?? .unstaged)
                }
            }
        }
    }

    /// Pull the current branch from origin.
    func pullChanges() {
        #if DEBUG
        dlog("diff.pull panel=\(id.uuidString.prefix(5))")
        #endif
        detectCurrentBranch { [weak self] branch in
            DispatchQueue.main.async {
                guard let self, let branch else {
                    self?.lastGitError = String(localized: "diff.error.noBranch", defaultValue: "Could not detect current branch.")
                    self?.isPerformingGitAction = false
                    return
                }
                self.runGitAction(args: ["pull", "origin", branch], label: "pull") { [weak self] in
                    self?.switchMode(self?.currentMode ?? .unstaged)
                }
            }
        }
    }

    /// Detect the current branch name asynchronously.
    private func detectCurrentBranch(completion: @escaping @Sendable (String?) -> Void) {
        isPerformingGitAction = true
        let repoURL = URL(fileURLWithPath: repoPath)
        let panelId = id

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
            process.currentDirectoryURL = repoURL

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                #if DEBUG
                DispatchQueue.main.async {
                    dlog("diff.detectBranch.error panel=\(panelId.uuidString.prefix(5)) error=\(error.localizedDescription)")
                }
                #endif
                completion(nil)
                return
            }

            process.waitUntilExit()

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus != 0 || (branch?.isEmpty ?? true) {
                completion(nil)
            } else {
                completion(branch)
            }
        }
    }

    /// Run a git mutation command and call onSuccess on completion.
    private func runGitAction(args: [String], label: String, onSuccess: @escaping @MainActor () -> Void) {
        guard !isClosed else { return }
        isPerformingGitAction = true
        lastGitError = nil

        let repoURL = URL(fileURLWithPath: repoPath)
        let panelId = id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = repoURL

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                #if DEBUG
                DispatchQueue.main.async {
                    dlog("diff.\(label).launchError panel=\(panelId.uuidString.prefix(5)) error=\(error.localizedDescription)")
                }
                #endif
                DispatchQueue.main.async {
                    self?.lastGitError = error.localizedDescription
                    self?.isPerformingGitAction = false
                }
                return
            }

            process.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""

            #if DEBUG
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let outOutput = String(data: outData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                dlog("diff.\(label).done panel=\(panelId.uuidString.prefix(5)) status=\(process.terminationStatus) stdout=\(outOutput.prefix(200))")
            }
            #endif

            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                if process.terminationStatus != 0 {
                    let msg = errOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastGitError = msg.isEmpty ? String(localized: "diff.error.unknown", defaultValue: "Git command failed.") : msg
                    self.isPerformingGitAction = false
                    #if DEBUG
                    dlog("diff.\(label).failed panel=\(panelId.uuidString.prefix(5)) stderr=\(msg.prefix(200))")
                    #endif
                } else {
                    self.isPerformingGitAction = false
                    onSuccess()
                    #if DEBUG
                    dlog("diff.\(label).success panel=\(panelId.uuidString.prefix(5))")
                    #endif
                }
            }
        }
    }

    // MARK: - Git execution

    private func runGitDiff(args: [String]) {
        guard !isClosed else { return }
        isLoading = true

        let repoURL = URL(fileURLWithPath: repoPath)
        let panelId = id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = repoURL

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                #if DEBUG
                DispatchQueue.main.async {
                    dlog("diff.gitError panel=\(panelId.uuidString.prefix(5)) error=\(error.localizedDescription)")
                }
                #endif
                DispatchQueue.main.async {
                    self?.diffContent = ""
                    self?.isLoading = false
                }
                return
            }

            process.waitUntilExit()

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            #if DEBUG
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            if !errOutput.isEmpty {
                DispatchQueue.main.async {
                    dlog("diff.gitStderr panel=\(panelId.uuidString.prefix(5)) stderr=\(errOutput.prefix(200))")
                }
            }
            #endif

            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                self.diffContent = output
                self.isLoading = false

                #if DEBUG
                dlog("diff.loaded panel=\(panelId.uuidString.prefix(5)) lines=\(output.components(separatedBy: "\n").count)")
                #endif
            }
        }
    }
}
