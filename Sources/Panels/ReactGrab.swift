import BreeBrowser
import Foundation
import WebKit

#if DEBUG
import Bonsplit
#endif

struct ReactGrabShortcutPanelSnapshot: Equatable {
    let id: UUID
    let panelType: PanelType
    let isFocused: Bool
}

struct ReactGrabShortcutRoute: Equatable {
    let browserPanelId: UUID
    let returnTerminalPanelId: UUID?
}

func resolveReactGrabShortcutRoute(
    panels: [ReactGrabShortcutPanelSnapshot]
) -> ReactGrabShortcutRoute? {
    guard let focusedPanel = panels.first(where: \.isFocused) else { return nil }

    if focusedPanel.panelType == .browser {
        return ReactGrabShortcutRoute(
            browserPanelId: focusedPanel.id,
            returnTerminalPanelId: nil
        )
    }

    guard focusedPanel.panelType == .terminal else { return nil }

    let browserPanels = panels.filter { $0.panelType == .browser }
    guard browserPanels.count == 1, let browserPanel = browserPanels.first else {
        return nil
    }

    return ReactGrabShortcutRoute(
        browserPanelId: browserPanel.id,
        returnTerminalPanelId: focusedPanel.id
    )
}

enum ReactGrabPastebackNotificationKey {
    static let workspaceId = "workspaceId"
    static let browserPanelId = "browserPanelId"
    static let returnPanelId = "returnPanelId"
    static let content = "content"
}

private enum ReactGrabPastebackContentFilter {
    private static let dangerousScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{FEFF}",
    ]

    static func filtered(_ text: String) -> String {
        String(text.unicodeScalars.filter { !dangerousScalars.contains($0) })
    }
}

// MARK: - Script Loader

/// Loads the react-grab script bundled with the app (MIT, react-grab 0.1.29,
/// Resources/browser-repl/vendor/react-grab.global.js). Patched vs upstream: the Google Fonts
/// link injection and the react-grab.com version ping are removed. Never touches the network.
enum ReactGrabScriptLoader {
    private static let script: String? = {
        guard let url = Bundle.main.url(
            forResource: "react-grab.global",
            withExtension: "js",
            subdirectory: "browser-repl/vendor"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    static func fetch() async -> String? { script }
}

// MARK: - WKScriptMessageHandler

private let reactGrabMessageHandlerName = "breeReactGrab"

enum ReactGrabBridgeMessage {
    case stateChange(isActive: Bool)
    case copySuccess(content: String, token: String?)

    init?(body: [String: Any]) {
        let type = body["type"] as? String ?? "stateChange"
        switch type {
        case "stateChange":
            guard let isActive = body["isActive"] as? Bool else { return nil }
            self = .stateChange(isActive: isActive)
        case "copySuccess":
            guard let content = body["content"] as? String else { return nil }
            self = .copySuccess(content: content, token: body["token"] as? String)
        default:
            return nil
        }
    }
}

class ReactGrabMessageHandler: NSObject, WKScriptMessageHandler {
    private let isCurrent: @MainActor () -> Bool
    private let onMessage: @MainActor (ReactGrabBridgeMessage, _ isMainFrame: Bool) -> Void

    init(
        isCurrent: @escaping @MainActor () -> Bool,
        onMessage: @escaping @MainActor (ReactGrabBridgeMessage, _ isMainFrame: Bool) -> Void
    ) {
        self.isCurrent = isCurrent
        self.onMessage = onMessage
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let bridgeMessage = ReactGrabBridgeMessage(body: body) else { return }
        let isMainFrame = message.frameInfo.isMainFrame
        #if DEBUG
        switch bridgeMessage {
        case .stateChange(let isActive):
            breeDebugLog("reactGrab.messageHandler type=stateChange isActive=\(isActive) mainFrame=\(isMainFrame ? 1 : 0)")
        case .copySuccess(let content, _):
            breeDebugLog("reactGrab.messageHandler type=copySuccess len=\(content.count) mainFrame=\(isMainFrame ? 1 : 0)")
        }
        #endif
        Task { @MainActor in
            guard isCurrent() else { return }
            #if DEBUG
            switch bridgeMessage {
            case .stateChange(let isActive):
                breeDebugLog("reactGrab.messageHandler.mainActor type=stateChange isActive=\(isActive)")
            case .copySuccess(let content, _):
                breeDebugLog("reactGrab.messageHandler.mainActor type=copySuccess len=\(content.count)")
            }
            #endif
            onMessage(bridgeMessage, isMainFrame)
        }
    }
}

// MARK: - BrowserPanel extension

extension BrowserPanel {
    /// Isolated content world for the React Grab native bridge.
    ///
    /// The script message handler, the relay, and the round-trip token all
    /// live here. A content world shares the DOM but not JavaScript globals,
    /// so page scripts can neither post to the native handler nor read the
    /// token; only the bree-injected relay in this world can. The react-grab
    /// library itself stays in the page world (component inspection needs
    /// page-world React internals) and talks to the relay through
    /// `window.postMessage` without any native authority.
    static let reactGrabContentWorld = WKContentWorld.world(name: reactGrabMessageHandlerName)

    func setupReactGrabMessageHandler(for webView: WKWebView) {
        let handler = ReactGrabMessageHandler(
            isCurrent: webViewObservationValidator(for: webView)
        ) { [weak self] message, isMainFrame in
            self?.handleReactGrabBridgeMessage(message, isMainFrame: isMainFrame)
        }
        reactGrabMessageHandler = handler
        webView.configuration.userContentController.add(
            handler,
            contentWorld: Self.reactGrabContentWorld,
            name: reactGrabMessageHandlerName
        )
    }

    func tearDownReactGrabMessageHandler(for webView: WKWebView, reason: String = "unspecified") {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: reactGrabMessageHandlerName,
            contentWorld: Self.reactGrabContentWorld
        )
        reactGrabMessageHandler = nil
        resetReactGrabState(reason: reason)
    }

    func armReactGrabRoundTrip(returnTo panelId: UUID) {
#if DEBUG
        breeDebugLog(
            "reactGrab.pasteback h3.arm " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "return=\(panelId.uuidString.prefix(5))"
        )
#endif
        reactGrabPasteback.arm(returnPanelId: panelId)
    }

    func clearReactGrabRoundTrip(reason: String = "unspecified") {
#if DEBUG
        let previousTarget = reactGrabPasteback.armedReturnPanelId.map {
            String($0.uuidString.prefix(5))
        } ?? "nil"
        breeDebugLog(
            "reactGrab.pasteback h3.clear " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) previous=\(previousTarget)"
        )
#endif
        reactGrabPasteback.disarm()
    }

    func handleReactGrabBridgeMessage(_ message: ReactGrabBridgeMessage, isMainFrame: Bool) {
        switch message {
        case .stateChange(let isActive):
            guard isMainFrame else { return }
            isReactGrabActive = isActive
#if DEBUG
            let pendingTarget = reactGrabPasteback.armedReturnPanelId.map {
                String($0.uuidString.prefix(5))
            } ?? "nil"
            breeDebugLog(
                "reactGrab.pasteback h3.stateChange " +
                "workspace=\(workspaceId.uuidString.prefix(5)) " +
                "browser=\(id.uuidString.prefix(5)) " +
                "isActive=\(isActive ? 1 : 0) pending=\(pendingTarget)"
            )
#endif
        case .copySuccess(let content, let token):
            let verdict = reactGrabPasteback.acceptDelivery(
                token: token,
                contentUTF8Count: content.utf8.count,
                isMainFrame: isMainFrame
            )
            switch verdict {
            case .accepted(let returnPanelId):
#if DEBUG
                breeDebugLog(
                    "reactGrab.pasteback h3.copySuccess " +
                    "workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "browser=\(id.uuidString.prefix(5)) " +
                    "return=\(returnPanelId.uuidString.prefix(5)) len=\(content.count)"
                )
#endif
                let filteredContent = ReactGrabPastebackContentFilter.filtered(content)
                NotificationCenter.default.post(
                    name: .reactGrabDidCopySelection,
                    object: nil,
                    userInfo: [
                        ReactGrabPastebackNotificationKey.workspaceId: workspaceId,
                        ReactGrabPastebackNotificationKey.browserPanelId: id,
                        ReactGrabPastebackNotificationKey.returnPanelId: returnPanelId,
                        ReactGrabPastebackNotificationKey.content: filteredContent,
                    ]
                )
            case .rejectedSubframe, .rejectedUnarmed, .rejectedTokenMismatch, .rejectedOversizeContent:
#if DEBUG
                breeDebugLog(
                    "reactGrab.pasteback h3.copySuccess.drop " +
                    "workspace=\(workspaceId.uuidString.prefix(5)) " +
                    "browser=\(id.uuidString.prefix(5)) reason=\(verdict) len=\(content.count)"
                )
#endif
                return
            }
        }
    }

    /// Installs the relay in the isolated world's main frame. Idempotent per
    /// document; the relay owns the only path to the native handler.
    private func installReactGrabRelay() async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                ReactGrabBridgeScripts.relaySource(handlerName: reactGrabMessageHandlerName),
                in: nil,
                in: Self.reactGrabContentWorld
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? Bool) ?? false)
                case .failure(let error):
#if DEBUG
                    breeDebugLog("reactGrab.relay.install.error error=\(error.localizedDescription)")
#endif
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Pushes the currently armed token (or a disarm) to the isolated-world
    /// relay. The token never transits the page world.
    @discardableResult
    func syncReactGrabRelayToken() async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                ReactGrabBridgeScripts.tokenSyncSource(token: reactGrabPasteback.tokenForRelaySync),
                in: nil,
                in: Self.reactGrabContentWorld
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? Bool) ?? false)
                case .failure(let error):
#if DEBUG
                    breeDebugLog("reactGrab.relay.tokenSync.error error=\(error.localizedDescription)")
#endif
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func injectReactGrab() async {
        #if DEBUG
        breeDebugLog("reactGrab.inject.start")
        #endif
        guard let scriptSource = await ReactGrabScriptLoader.fetch() else {
            #if DEBUG
            breeDebugLog("reactGrab.inject.fetchFailed")
            #endif
            return
        }
        #if DEBUG
        breeDebugLog("reactGrab.inject.fetched len=\(scriptSource.count)")
        #endif

        guard await installReactGrabRelay() else {
            #if DEBUG
            breeDebugLog("reactGrab.inject.relayInstallFailed")
            #endif
            isReactGrabActive = false
            return
        }
        await syncReactGrabRelayToken()

        let combined = ReactGrabBridgeScripts.pageBridgeSource() + "\n" + scriptSource
        #if DEBUG
        breeDebugLog("reactGrab.inject.evalJS len=\(combined.count)")
        #endif
        webView.evaluateJavaScript(combined, in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result {
                #if DEBUG
                breeDebugLog("reactGrab.inject.evalJS.done error=\(error.localizedDescription)")
                #endif
                NSLog("ReactGrab: injection failed: %@", error.localizedDescription)
                Task { @MainActor in self?.isReactGrabActive = false }
            } else {
                #if DEBUG
                breeDebugLog("reactGrab.inject.evalJS.done error=none")
                #endif
            }
        }
        #if DEBUG
        breeDebugLog("reactGrab.inject.end")
        #endif
    }

    private func toggleReactGrab() {
        #if DEBUG
        breeDebugLog("reactGrab.toggle.start")
        #endif
        let script = "window.__REACT_GRAB__?.toggle()"
        webView.evaluateJavaScript(script, completionHandler: nil)
        #if DEBUG
        breeDebugLog("reactGrab.toggle.end")
        #endif
    }

    func toggleOrInjectReactGrab() async {
        if isReactGrabActive {
            toggleReactGrab()
        } else {
            guard await prepareForReactGrabActivation(reason: "reactGrab.toggle") else { return }
            await injectReactGrab()
        }
    }

    func ensureReactGrabActive() async {
        guard await prepareForReactGrabActivation(reason: "reactGrab.ensureActive") else { return }
        if isReactGrabActive {
            guard reactGrabPasteback.isArmed else { return }
            if await syncReactGrabRelayToken() {
                return
            }
        }
        await injectReactGrab()
    }

    func resetReactGrabState(
        preserveRoundTrip: Bool = false,
        reason: String = "unspecified"
    ) {
#if DEBUG
        let pendingTarget = reactGrabPasteback.armedReturnPanelId.map {
            String($0.uuidString.prefix(5))
        } ?? "nil"
        breeDebugLog(
            "reactGrab.pasteback h3.reset " +
            "workspace=\(workspaceId.uuidString.prefix(5)) " +
            "browser=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) preserve=\(preserveRoundTrip ? 1 : 0) " +
            "pending=\(pendingTarget) active=\(isReactGrabActive ? 1 : 0)"
        )
#endif
        isReactGrabActive = false
        if !preserveRoundTrip {
            clearReactGrabRoundTrip(reason: reason)
        }
    }
}
