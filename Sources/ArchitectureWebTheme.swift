import BreeFoundation
import Foundation

/// Bree's live palette as CSS variables for the Architecture board. `--accent` is left to the page.
enum ArchitectureWebTheme {
    /// `--paper` the popover surface, `--paper-2` raised surface, `--ink` text, `--muted` secondary text,
    /// `--soft` tertiary glyphs, `--rule` separators, `--accent-tint` the quiet selection fill.
    static func cssVariables(_ palette: BreeChromePalette) -> String {
        func hex(_ role: BreeChromePalette.Role) -> String { palette.rgba(role).cssHex }
        return [
            ("paper", hex(.surfaceOverlay)), ("paper-2", hex(.surfaceRaised)), ("ink", hex(.textPrimary)),
            ("muted", hex(.textSecondary)), ("soft", hex(.glyphTertiary)), ("rule", hex(.separator)),
            ("accent-tint", hex(.selectedQuiet)),
        ].map { "--\($0.0):\($0.1) !important;" }.joined()
    }

    /// Document-start user script: defines the variables (and the anchor map) before the page runs.
    static func userScript(palette: BreeChromePalette, anchorsJSON: String, stringsJSON: String? = nil) -> String {
        let stringsJSON = stringsJSON ?? chromeStringsJSON()
        return """
        (function(){
          var s=document.createElement('style');s.id='bree-palette';
          s.textContent=':root{\(cssVariables(palette))}';
          (document.head||document.documentElement).appendChild(s);
          window.breeWikiAnchors=\(anchorsJSON);
          window.breeStrings=\(stringsJSON);
        })();
        \(codeLinkScript)
        """
    }

    /// Localized chrome of the shell page (`window.breeStrings`); the page falls back to English for a missing key.
    static func chromeStrings() -> [String: String] {
        [
            // UI language of the app: chrome elements carry it as `lang`, so CSS uppercase follows the UI language, not the document's.
            "_lang": Bundle.main.preferredLocalizations.first ?? "en",
            "reading_order": String(localized: "architecture.chrome.reading_order", defaultValue: "Reading order"),
            "prev": String(localized: "architecture.chrome.prev", defaultValue: "Previous diagram"),
            "prev_title": String(localized: "architecture.chrome.prev_title", defaultValue: "Previous diagram ([)"),
            "next": String(localized: "architecture.chrome.next", defaultValue: "Next diagram"),
            "next_title": String(localized: "architecture.chrome.next_title", defaultValue: "Next diagram (])"),
            "contents": String(localized: "architecture.chrome.contents", defaultValue: "Contents"),
            "node_details": String(localized: "architecture.chrome.node_details", defaultValue: "Node details"),
            "zoom": String(localized: "architecture.chrome.zoom", defaultValue: "Zoom"),
            "fit": String(localized: "architecture.chrome.fit", defaultValue: "Fit"),
            "fit_aria": String(localized: "architecture.chrome.fit_aria", defaultValue: "Fit to view"),
            "fit_title": String(localized: "architecture.chrome.fit_title", defaultValue: "Fit to view (Cmd 0, double-click)"),
            "zoom_out": String(localized: "architecture.chrome.zoom_out", defaultValue: "Zoom out"),
            "zoom_out_title": String(localized: "architecture.chrome.zoom_out_title", defaultValue: "Zoom out (Cmd -)"),
            "zoom_level": String(localized: "architecture.chrome.zoom_level", defaultValue: "Zoom level"),
            "zoom_level_title": String(localized: "architecture.chrome.zoom_level_title", defaultValue: "Zoom level (Cmd 1 = 100%)"),
            "zoom_in": String(localized: "architecture.chrome.zoom_in", defaultValue: "Zoom in"),
            "zoom_in_title": String(localized: "architecture.chrome.zoom_in_title", defaultValue: "Zoom in (Cmd =)"),
            "back_to": String(localized: "architecture.chrome.back_to", defaultValue: "Back to {name}"),
            "close_aria": String(localized: "architecture.chrome.close_aria", defaultValue: "Close card (Esc)"),
            "close_title": String(localized: "architecture.chrome.close_title", defaultValue: "Close (Esc)"),
            "more": String(localized: "architecture.chrome.more", defaultValue: "More"),
            "less": String(localized: "architecture.chrome.less", defaultValue: "Less"),
            "what": String(localized: "architecture.chrome.what", defaultValue: "What it does"),
            "why": String(localized: "architecture.chrome.why", defaultValue: "Why it exists"),
            "code": String(localized: "architecture.chrome.code", defaultValue: "In the code"),
            "watch": String(localized: "architecture.chrome.watch", defaultValue: "Watch out"),
            "links": String(localized: "architecture.chrome.links", defaultValue: "Connections"),
            "flows": String(localized: "architecture.chrome.flows", defaultValue: "Flows"),
            "lane": String(localized: "architecture.chrome.lane", defaultValue: "Lane"),
            "unverified": String(localized: "architecture.chrome.unverified", defaultValue: "Unverified: this node's code link could not be checked."),
            "wiki": String(localized: "architecture.chrome.wiki", defaultValue: "Wiki"),
            "agent_wrote": String(localized: "architecture.chrome.agent_wrote", defaultValue: "Written by agent"),
            "changes": String(localized: "architecture.chrome.changes", defaultValue: "Changes"),
            "last_generated": String(localized: "architecture.chrome.last_generated", defaultValue: "Last generated"),
            "legend": String(localized: "architecture.chrome.legend", defaultValue: "Legend"),
        ]
    }

    /// The table as JSON safe inside a script source.
    static func chromeStringsJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: chromeStrings(), options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text.replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// A code link is `<a href="hm/graph.py#L129">`, relative to `.architecture/`. WebKit resolves that to
    /// `.architecture/hm/graph.py`, which does not exist (sources live at the repo root), and then drops the
    /// navigation without ever asking the navigation delegate: the click did nothing. Local, non-HTML file
    /// links are therefore sent to Bree as a message (the resolver tries root and `.architecture/`).
    static let codeLinkScript = """
        document.addEventListener('click',function(e){
          var a=e.target&&e.target.closest&&e.target.closest('a[href]');
          if(!a||e.defaultPrevented||a.protocol!=='file:'||/\\.html?$/i.test(a.pathname)){return;}
          e.preventDefault();
          try{window.webkit.messageHandlers.bree.postMessage({type:'openCode',href:a.href,meta:!!e.metaKey});}catch(x){}
        },true);
        """

    /// Re-applies the variables to a loaded page after a theme change.
    static func updateScript(palette: BreeChromePalette) -> String {
        "var s=document.getElementById('bree-palette');if(s){s.textContent=':root{\(cssVariables(palette))}';}"
    }
}

extension BreeRGBA {
    /// `#RRGGBB`, or `#RRGGBBAA` when translucent.
    var cssHex: String {
        func byte(_ v: Double) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 0.999 ? base : base + String(format: "%02X", byte(alpha))
    }
}
