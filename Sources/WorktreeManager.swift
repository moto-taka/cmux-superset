import Foundation

/// Manages git worktree operations for cmux workspaces.
///
/// Heavy git operations (`createWorktree`, `removeWorktree`, `listWorktrees`, etc.)
/// run synchronous `Process` calls and must be called from a background queue.
/// Only lightweight property access (`worktreeBaseDirectory`) is `@MainActor`.
@MainActor
final class WorktreeManager: ObservableObject {
    /// Shared instance
    static let shared = WorktreeManager()

    /// Information about a git worktree
    struct WorktreeInfo: Identifiable, Equatable, Sendable {
        let id: String  // worktree path
        let path: String
        let branch: String
        let isMain: Bool
        let head: String  // commit SHA
    }

    /// Base directory for worktrees (configurable).
    /// When non-nil, worktrees are placed under this directory instead of the
    /// default `.<repoName>-worktrees` sibling of the repository root.
    @Published var worktreeBaseDirectory: String?

    private init() {}

    // MARK: - Git Repository Detection

    /// Find the git repository root for a given directory.
    /// Safe to call from any thread.
    nonisolated func findGitRoot(for directory: String) -> String? {
        let result = runGitSync(args: ["rev-parse", "--show-toplevel"], in: directory)
        return result?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if a directory is inside a git repository.
    /// Safe to call from any thread.
    nonisolated func isGitRepository(_ directory: String) -> Bool {
        return findGitRoot(for: directory) != nil
    }

    // MARK: - Worktree Operations

    /// List all worktrees for a repository.
    ///
    /// This runs a synchronous git process -- call from a background queue.
    nonisolated func listWorktrees(repoPath: String) -> [WorktreeInfo] {
        guard let output = runGitSync(args: ["worktree", "list", "--porcelain"], in: repoPath) else {
            return []
        }
        return parseWorktreeList(output)
    }

    /// Create a new worktree with a new branch.
    ///
    /// Returns the worktree path on success.
    /// This runs synchronous git processes -- call from a background queue.
    nonisolated func createWorktree(
        repoPath: String,
        branchName: String,
        baseBranch: String? = nil
    ) -> Result<String, WorktreeError> {
        let sanitizedBranch = sanitizeBranchName(branchName)
        let worktreePath = resolveWorktreePath(repoPath: repoPath, branchName: sanitizedBranch)

        // Check if path already exists
        if FileManager.default.fileExists(atPath: worktreePath) {
            return .failure(.pathAlreadyExists(worktreePath))
        }

        // Determine base branch
        let base = baseBranch ?? detectDefaultBranch(repoPath: repoPath) ?? "main"

        // Fetch latest from remote first (best-effort; offline repos still work)
        _ = runGitSync(args: ["fetch", "origin", base], in: repoPath)

        // Try creating the worktree against the remote tracking branch first.
        // If `origin/<base>` does not exist (e.g. no remote), fall back to the
        // local branch.
        let remoteBased = ["worktree", "add", "-b", sanitizedBranch, worktreePath, "origin/\(base)"]
        let localBased  = ["worktree", "add", "-b", sanitizedBranch, worktreePath, base]

        let output: String?
        if let remoteOutput = runGitSync(args: remoteBased, in: repoPath, includeStderr: true),
           FileManager.default.fileExists(atPath: worktreePath) {
            output = remoteOutput
        } else {
            // Remote ref missing -- try local branch
            output = runGitSync(args: localBased, in: repoPath, includeStderr: true)
        }

        // Verify the worktree was created
        if FileManager.default.fileExists(atPath: worktreePath) {
            return .success(worktreePath)
        } else {
            return .failure(.creationFailed(output ?? "git worktree add produced no output"))
        }
    }

    /// Remove a worktree.
    ///
    /// This runs a synchronous git process -- call from a background queue.
    nonisolated func removeWorktree(
        repoPath: String,
        worktreePath: String,
        force: Bool = false
    ) -> Result<Void, WorktreeError> {
        var args = ["worktree", "remove", worktreePath]
        if force { args.insert("--force", at: 2) }

        guard let _ = runGitSync(args: args, in: repoPath, includeStderr: true) else {
            return .failure(.removalFailed("Failed to run git worktree remove"))
        }

        return .success(())
    }

    /// Prune stale worktree entries.
    ///
    /// This runs a synchronous git process -- call from a background queue.
    nonisolated func pruneWorktrees(repoPath: String) {
        _ = runGitSync(args: ["worktree", "prune"], in: repoPath)
    }

    // MARK: - Branch Detection

    /// Detect the default branch (main, master, develop, etc.).
    /// Safe to call from any thread.
    nonisolated func detectDefaultBranch(repoPath: String) -> String? {
        // Try HEAD of origin
        if let output = runGitSync(args: ["symbolic-ref", "refs/remotes/origin/HEAD"], in: repoPath) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.split(separator: "/").last {
                return String(last)
            }
        }
        // Fallback: check common branch names
        for branch in ["main", "master", "develop", "trunk"] {
            if let _ = runGitSync(args: ["rev-parse", "--verify", branch], in: repoPath) {
                return branch
            }
        }
        return nil
    }

    /// Get current branch name for a directory.
    /// Safe to call from any thread.
    nonisolated func currentBranch(for directory: String) -> String? {
        let result = runGitSync(args: ["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
        return result?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private helpers

    private nonisolated func resolveWorktreePath(repoPath: String, branchName: String) -> String {
        // Place worktrees next to the main repo, in a .<repoName>-worktrees directory
        let parentDir = (repoPath as NSString).deletingLastPathComponent
        let repoName = (repoPath as NSString).lastPathComponent
        let worktreeDir = (parentDir as NSString).appendingPathComponent(".\(repoName)-worktrees")

        // Create the worktrees directory if it doesn't exist
        try? FileManager.default.createDirectory(atPath: worktreeDir, withIntermediateDirectories: true)

        return (worktreeDir as NSString).appendingPathComponent(branchName)
    }

    private nonisolated func sanitizeBranchName(_ name: String) -> String {
        // Replace spaces and special chars with hyphens
        var sanitized = name.lowercased()
        sanitized = sanitized.replacingOccurrences(of: " ", with: "-")
        sanitized = sanitized.replacingOccurrences(of: "[^a-z0-9\\-_/.]", with: "", options: .regularExpression)
        // Remove consecutive hyphens
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-._/"))
        return sanitized.isEmpty ? "worktree-\(UUID().uuidString.prefix(8).lowercased())" : sanitized
    }

    private nonisolated func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentHead: String?
        var currentBranch: String?
        var isBareBranch = false

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Save previous entry
                if let path = currentPath {
                    let branch = currentBranch ?? "detached"
                    worktrees.append(WorktreeInfo(
                        id: path,
                        path: path,
                        branch: branch,
                        isMain: isBareBranch || worktrees.isEmpty,
                        head: currentHead ?? ""
                    ))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentHead = nil
                currentBranch = nil
                isBareBranch = false
            } else if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let fullBranch = String(line.dropFirst("branch ".count))
                currentBranch = fullBranch.replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "bare" {
                isBareBranch = true
            }
        }

        // Save last entry
        if let path = currentPath {
            let branch = currentBranch ?? "detached"
            worktrees.append(WorktreeInfo(
                id: path,
                path: path,
                branch: branch,
                isMain: isBareBranch || worktrees.isEmpty,
                head: currentHead ?? ""
            ))
        }

        return worktrees
    }

    /// Run a git command synchronously.
    ///
    /// - Important: This blocks the calling thread.  Never call from the main thread
    ///   for operations that may touch the network (fetch) or do I/O-heavy work.
    private nonisolated func runGitSync(
        args: [String],
        in directory: String,
        includeStderr: Bool = false
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        if includeStderr {
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
        } else {
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 && !includeStderr {
                return nil
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Error types

    enum WorktreeError: Error, LocalizedError, Sendable {
        case pathAlreadyExists(String)
        case creationFailed(String)
        case removalFailed(String)
        case notAGitRepository

        var errorDescription: String? {
            switch self {
            case .pathAlreadyExists(let path):
                return String(
                    localized: "worktree.error.pathExists",
                    defaultValue: "Worktree path already exists: \(path)"
                )
            case .creationFailed(let detail):
                return String(
                    localized: "worktree.error.creationFailed",
                    defaultValue: "Failed to create worktree: \(detail)"
                )
            case .removalFailed(let detail):
                return String(
                    localized: "worktree.error.removalFailed",
                    defaultValue: "Failed to remove worktree: \(detail)"
                )
            case .notAGitRepository:
                return String(
                    localized: "worktree.error.notGitRepo",
                    defaultValue: "Not a git repository"
                )
            }
        }
    }
}
