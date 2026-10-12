import Foundation
import GhosttyKit

/// App-side view of the shell input line, built on the fork's OSC 133 aware
/// `ghostty_surface_prompt_input*` calls. All of them return false off the
/// primary screen or when the cursor is not at a prompt, which is what keeps
/// completion and Cmd+A out of vim, less and running commands.
enum TerminalPromptInput {
    struct Info {
        /// Caret stops in the input region.
        var length: Int
        var caret: Int
        var hasSelection: Bool
        var selectionStart: Int
        var selectionEnd: Int
    }

    static func info(surface: ghostty_surface_t) -> Info? {
        var raw = ghostty_surface_prompt_input_s()
        guard ghostty_surface_prompt_input(surface, &raw) else { return nil }
        return Info(
            length: Int(raw.length),
            caret: Int(raw.caret),
            hasSelection: raw.has_selection,
            selectionStart: Int(raw.selection_start),
            selectionEnd: Int(raw.selection_end)
        )
    }

    /// Selects the whole input line for Cmd+A. Returns false (leaving the
    /// normal select-all to run) when there is no editable input to select.
    static func selectWholeInput(surface: ghostty_surface_t) -> Bool {
        guard let info = info(surface: surface), info.length > 0 else { return false }
        return ghostty_surface_select_prompt_input(surface, 0, UInt32(info.length))
    }

    /// The input text and the caret in characters, or nil when the surface is
    /// not at an editable prompt.
    ///
    /// Ghostty reports only the length and caret, so the text is read through
    /// a temporary selection of the whole input, which is then restored. A
    /// selection outside the input is never disturbed: the read is skipped
    /// instead.
    static func text(surface: ghostty_surface_t) -> (text: String, caret: Int)? {
        guard let info = info(surface: surface) else { return nil }
        guard info.length > 0 else { return ("", 0) }
        if ghostty_surface_has_selection(surface), !info.hasSelection { return nil }
        guard ghostty_surface_select_prompt_input(surface, 0, UInt32(info.length)) else { return nil }
        defer {
            if info.hasSelection {
                _ = ghostty_surface_select_prompt_input(
                    surface, UInt32(info.selectionStart), UInt32(info.selectionEnd)
                )
            } else {
                _ = ghostty_surface_clear_selection(surface)
            }
        }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let string: String
        if let pointer = text.text, text.text_len > 0 {
            string = String(decoding: Data(bytes: pointer, count: Int(text.text_len)), as: UTF8.self)
        } else {
            string = ""
        }
        return (string, info.caret)
    }
}
