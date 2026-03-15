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
