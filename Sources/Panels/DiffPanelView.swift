import AppKit
import SwiftUI
import WebKit
import Bonsplit

/// SwiftUI view that renders a DiffPanel's git diff output using a WebView-based diff viewer.
struct DiffPanelView: View {
    @ObservedObject var panel: DiffPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var showCommitSheet = false
    @State private var commitMessage = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            diffToolbar
            Divider()

            ZStack {
                DiffWebView(
                    diffContent: panel.diffContent,
                    colorScheme: colorScheme
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if panel.isLoading {
                    loadingOverlay
                }
            }
        }
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            if isVisibleInUI {
                DiffPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        .sheet(isPresented: $showCommitSheet) {
            commitSheet
        }
        .alert(
            String(localized: "diff.error.title", defaultValue: "Error"),
            isPresented: .init(
                get: { panel.lastGitError != nil },
                set: { if !$0 { panel.lastGitError = nil } }
            )
        ) {
            Button(String(localized: "diff.error.ok", defaultValue: "OK"), role: .cancel) {
                panel.lastGitError = nil
            }
        } message: {
            if let error = panel.lastGitError {
                Text(error)
            }
        }
    }

    // MARK: - Toolbar

    private var diffToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(DiffMode.allCases, id: \.rawValue) { mode in
                    Button {
                        panel.switchMode(mode)
                    } label: {
                        Text(mode.localizedTitle)
                            .font(.system(size: 11, weight: panel.currentMode == mode ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                panel.currentMode == mode
                                    ? (colorScheme == .dark
                                        ? Color.white.opacity(0.12)
                                        : Color.black.opacity(0.08))
                                    : Color.clear
                            )
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(panel.currentMode == mode ? .primary : .secondary)
                }
            }

            Spacer()

            Button {
                showCommitSheet = true
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(panel.isPerformingGitAction)
            .help(String(localized: "diff.toolbar.commit", defaultValue: "Commit"))

            Button {
                panel.pushChanges()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(panel.isPerformingGitAction)
            .help(String(localized: "diff.toolbar.push", defaultValue: "Push"))

            Button {
                panel.pullChanges()
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(panel.isPerformingGitAction)
            .help(String(localized: "diff.toolbar.pull", defaultValue: "Pull"))

            Button {
                panel.switchMode(panel.currentMode)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "diff.toolbar.refresh", defaultValue: "Refresh"))

            if panel.isPerformingGitAction {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Loading

    private var loadingOverlay: some View {
        VStack {
            ProgressView()
                .scaleEffect(0.8)
                .padding(.top, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }

    // MARK: - Commit Sheet

    private var commitSheet: some View {
        VStack(spacing: 16) {
            Text(String(localized: "diff.commit.title", defaultValue: "Commit Changes"))
                .font(.headline)

            TextField(
                String(localized: "diff.commit.placeholder", defaultValue: "Commit message"),
                text: $commitMessage
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 300)

            HStack {
                Button(String(localized: "diff.commit.cancel", defaultValue: "Cancel")) {
                    commitMessage = ""
                    showCommitSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "diff.commit.confirm", defaultValue: "Commit")) {
                    let message = commitMessage
                    commitMessage = ""
                    showCommitSheet = false
                    panel.stageAll()
                    // Use a small delay to let stageAll finish before committing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        panel.commitChanges(message: message)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - DiffWebView (NSViewRepresentable)

/// NSViewRepresentable wrapper that hosts a WKWebView displaying a git diff
/// using the bundled diff-viewer.html.
struct DiffWebView: NSViewRepresentable {
    let diffContent: String
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        // Load the bundled diff viewer HTML.
        if let htmlURL = Bundle.main.url(forResource: "diff-viewer", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            context.coordinator.needsInitialUpdate = true
            context.coordinator.pendingDiff = diffContent
            context.coordinator.pendingIsDark = colorScheme == .dark

            // Set up navigation delegate to inject content after page load.
            webView.navigationDelegate = context.coordinator
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let isDark = colorScheme == .dark

        // If the page has not loaded yet, stash the pending values.
        if !context.coordinator.isPageLoaded {
            context.coordinator.pendingDiff = diffContent
            context.coordinator.pendingIsDark = isDark
            return
        }

        // Theme change.
        if context.coordinator.lastAppliedIsDark != isDark {
            context.coordinator.lastAppliedIsDark = isDark
            let jsTheme = "setTheme(\(isDark));"
            webView.evaluateJavaScript(jsTheme) { _, error in
                #if DEBUG
                if let error {
                    DispatchQueue.main.async {
                        dlog("diff.webView.themeError: \(error.localizedDescription)")
                    }
                }
                #endif
            }
        }

        // Diff content change.
        if context.coordinator.lastAppliedDiff != diffContent {
            context.coordinator.lastAppliedDiff = diffContent
            injectDiffContent(into: webView, diffContent: diffContent)
        }
    }

    private func injectDiffContent(into webView: WKWebView, diffContent: String) {
        // JSON-encode the diff string so it is safe for JavaScript injection.
        guard let jsonData = try? JSONEncoder().encode(diffContent),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        let js = "updateDiff(\(jsonString));"
        webView.evaluateJavaScript(js) { _, error in
            #if DEBUG
            if let error {
                DispatchQueue.main.async {
                    dlog("diff.webView.updateError: \(error.localizedDescription)")
                }
            }
            #endif
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var isPageLoaded: Bool = false
        var needsInitialUpdate: Bool = false
        var pendingDiff: String?
        var pendingIsDark: Bool?
        var lastAppliedDiff: String?
        var lastAppliedIsDark: Bool?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true

            // Apply pending theme.
            if let isDark = pendingIsDark {
                lastAppliedIsDark = isDark
                webView.evaluateJavaScript("setTheme(\(isDark));", completionHandler: nil)
            }

            // Apply pending diff content.
            if let diff = pendingDiff {
                lastAppliedDiff = diff
                if let jsonData = try? JSONEncoder().encode(diff),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    webView.evaluateJavaScript("updateDiff(\(jsonString));", completionHandler: nil)
                }
            }

            pendingDiff = nil
            pendingIsDark = nil

            #if DEBUG
            DispatchQueue.main.async {
                dlog("diff.webView.loaded")
            }
            #endif
        }
    }
}

// MARK: - Pointer Observer

/// Transparent overlay that observes left-clicks for panel focus requests
/// without intercepting them, allowing WebView interactions to pass through.
private struct DiffPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> DiffPanelPointerObserverView {
        let view = DiffPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: DiffPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class DiffPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }
}
