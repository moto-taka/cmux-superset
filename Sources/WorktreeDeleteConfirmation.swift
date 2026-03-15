import SwiftUI

/// A `ViewModifier` that presents a confirmation alert before deleting or closing a workspace.
///
/// For worktree-backed workspaces the alert warns that the git worktree and its branch will be
/// removed permanently.  For regular workspaces it shows a lighter "Close Workspace?" prompt.
struct WorktreeDeleteConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let workspaceName: String
    let isWorktree: Bool
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                isWorktree
                    ? String(localized: "worktree.delete.title", defaultValue: "Delete Worktree?")
                    : String(localized: "workspace.close.title", defaultValue: "Close Workspace?"),
                isPresented: $isPresented
            ) {
                Button(
                    String(localized: "worktree.delete.cancel", defaultValue: "Cancel"),
                    role: .cancel
                ) {}
                Button(
                    isWorktree
                        ? String(localized: "worktree.delete.confirm", defaultValue: "Delete Worktree")
                        : String(localized: "workspace.close.confirm", defaultValue: "Close"),
                    role: .destructive
                ) {
                    onConfirm()
                }
            } message: {
                if isWorktree {
                    Text(String(
                        localized: "worktree.delete.message",
                        defaultValue: "This will remove the git worktree and its branch. This action cannot be undone."
                    ))
                }
            }
    }
}

extension View {
    /// Attaches a delete/close confirmation alert for a workspace.
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls alert visibility.
    ///   - workspaceName: Display name of the workspace (used for context).
    ///   - isWorktree: When `true`, presents a destructive worktree-removal warning; otherwise shows a
    ///     lighter close prompt.
    ///   - onConfirm: Called when the user confirms the action.
    func worktreeDeleteConfirmation(
        isPresented: Binding<Bool>,
        workspaceName: String,
        isWorktree: Bool,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(WorktreeDeleteConfirmation(
            isPresented: isPresented,
            workspaceName: workspaceName,
            isWorktree: isWorktree,
            onConfirm: onConfirm
        ))
    }
}
