import Foundation

/// Panel-local provider switcher shortcuts, expressed independently of
/// AppKit and global hotkey registration (ported from CodexBar's
/// `ProviderSwitcherShortcuts`).
///
/// Actions: `previous`/`next` cycle the popover's provider tabs;
/// `select1`…`select9` jump to the nth visible tab ("all" counts first when
/// the local-cost tab is shown). Shortcuts are normalized strings like
/// `left`, `cmd+3`, `ctrl+alt+k`; `none` disables an action.
enum ProviderSwitcherShortcuts {
    enum Error: Swift.Error {
        case invalid(String)
    }

    static let actions = ["previous", "next"] + (1...9).map { "select\($0)" }
    static let defaults = Dictionary(uniqueKeysWithValues:
        zip(Self.actions, ["left", "right"] + (1...9).map { "cmd+\($0)" }))

    static func validated(_ overrides: [String: String]) throws -> [String: String] {
        guard Set(overrides.keys).isSubset(of: Set(Self.actions)) else {
            throw Error.invalid("Unknown switcher action")
        }
        var result = Self.defaults
        for (action, shortcut) in overrides {
            result[action] = try Self.normalized(shortcut)
        }
        let assigned = result.values.filter { $0 != "none" }
        guard Set(assigned).count == assigned.count else {
            throw Error.invalid("Switcher shortcuts must be unique")
        }
        return result
    }

    static func normalized(_ shortcut: String) throws -> String {
        let parts = shortcut.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts == ["none"] { return "none" }
        let modifiers = ["ctrl", "alt", "shift", "cmd"]
        let supplied = Array(parts.dropLast())
        guard let key = parts.last,
              Set(supplied).count == supplied.count,
              supplied.allSatisfy(modifiers.contains),
              ["left", "right", ","].contains(key)
              || (key.count == 1 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            throw Error.invalid("Use a letter, digit, left or right with ctrl/alt/shift/cmd")
        }
        let result = (modifiers.filter(supplied.contains) + [key]).joined(separator: "+")
        guard !["cmd+r", "cmd+q", "cmd+,", "cmd+h", "cmd+m", "cmd+w", "alt+cmd+h"].contains(result),
              ["left", "right"].contains(key) || supplied.contains(where: { $0 != "shift" })
        else {
            throw Error.invalid("That shortcut is reserved for a menu or system command")
        }
        return result
    }

    /// Map an AppKit key event to an action name, or nil when unmapped.
    static func action(characters: String, modifiers: [String], mapping: [String: String]) -> String? {
        let combination = (modifiers + [characters.lowercased()]).joined(separator: "+")
        return Self.actions.first { mapping[$0] == combination }
    }
}
