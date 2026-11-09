import AppKit
import Carbon
import Foundation
import ServiceManagement

/// Carbon virtual key codes, persisted independently from a keyboard's layout.
struct HotKeySpec: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let cancel = HotKeySpec(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey))
    static let toggle = HotKeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    static let hold = HotKeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | shiftKey))
    static let workflow = HotKeySpec(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))
    static let modeSwitcher = HotKeySpec(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
    static let supportedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    static let keyChoices: [(name: String, code: UInt32)] = [
        ("Escape", 53), ("Space", 49), ("Return", 36), ("Tab", 48),
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
        ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
        ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111)
    ]
    var isValid: Bool {
        Self.keyChoices.contains { $0.code == keyCode } && modifiers & ~Self.supportedModifiers == 0 &&
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        var carbon: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if flags.contains(flag) { carbon |= UInt32(value) }
        }
        return UInt32(keyCode) == self.keyCode && carbon == modifiers
    }

    var displayName: String {
        let prefix = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        return prefix + (Self.keyChoices.first { $0.code == keyCode }?.name ?? "Key \(keyCode)")
    }
    static func validationError(toggle: Self, hold: Self, modes: [DictationMode], switcher: Self? = nil, workflow: Self = .workflow, cancel: Self = .cancel) -> String? {
        let assignments = [("Cancel recording", cancel), ("Toggle recording", toggle), ("Hold to record", hold), ("Voice workflow", workflow)] + (switcher.map { [("Mode switcher", $0)] } ?? []) + modes.compactMap { mode in mode.shortcut.map { (mode.name, $0) } }
        var seen: [Self: String] = [:]
        for (name, key) in assignments {
            guard key.isValid else { return "\(name): choose a supported key with Control, Option, or Command." }
            if let owner = seen[key] { return "\(name) and \(owner) use the same shortcut (\(key.displayName))." }
            seen[key] = name
        }
        return nil
    }
}

/// This context is deliberately not Codable: it never belongs in the library or history.
struct CapturedContext: Equatable {
    static let maximumAge: TimeInterval = 120
    static let maximumCharacters = 8000
    var capturedAt: Date
    var application: String?
    var siteHost: String?
    var focusedText: String?
    var selectedText: String?
    var recentClipboard: String? = nil

    var isEmpty: Bool { focusedText == nil && selectedText == nil && recentClipboard == nil }
    func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= Self.maximumAge
    }
    /// Separate data message for rewriting. Never append context to a system instruction.
    func promptData(at now: Date = Date()) -> String? {
        guard isFresh(at: now), !isEmpty else { return nil }
        var values: [String: String] = [:]
        if let application { values["application"] = application }
        if let siteHost { values["site_host"] = siteHost }
        if let focusedText { values["focused_text"] = Self.sanitize(focusedText, limit: 4000) }
        if let selectedText { values["selected_text"] = Self.sanitize(selectedText, limit: 2000) }
        if let recentClipboard { values["recent_clipboard"] = Self.sanitize(recentClipboard, limit: 2000) }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), let result = String(data: data, encoding: .utf8) else { return nil }
        return result
    }
    static func sanitize(_ text: String?, limit: Int) -> String? {
        guard let text, limit > 0 else { return nil }
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }
}

enum ModeContextMatcher {
    static func host(from value: String?) -> String? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
    static func matches(mode: DictationMode, bundleID: String?, siteHost: String?) -> Bool {
        let apps = mode.appBundleIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let sites = mode.siteDomains.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !apps.isEmpty || !sites.isEmpty else { return false }
        let appMatches = apps.isEmpty || bundleID.map { apps.contains($0) } == true
        let siteMatches = sites.isEmpty || siteHost.map { host in
            sites.contains { domain in
                let normalized = Self.host(from: domain.contains("://") ? domain : "https://" + domain)
                guard let normalized else { return false }
                return host.lowercased() == normalized || host.lowercased().hasSuffix("." + normalized)
            }
        } == true
        return appMatches && siteMatches
    }
}

@MainActor
enum LoginItemService {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Launch at login is enabled"
        case .requiresApproval: return "Approve Cortala in System Settings → General → Login Items"
        case .notRegistered: return "Launch at login is off"
        case .notFound: return "Install Cortala.app in Applications to enable launch at login"
        @unknown default: return "Launch at login status is unavailable"
        }
    }
    /// Call only in response to the user changing the login-item setting.
    static func setEnabled(_ enabled: Bool) throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw ProviderError.message("Launch at login requires the packaged Cortala.app. Open the app from Applications and try again.")
        }
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
    }
}

/// Context requires stricter eligibility than ordinary text insertion.
enum ContextCapturePolicy {
    static func allows(metadata: [String], value: String? = nil, placeholder: String? = nil, secure: Bool = false) -> Bool {
        guard !secure else { return false }
        let description = metadata.joined(separator: " ").lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let forbidden = ["password", "passcode", "securetext", "protected", "omnibox", "urlfield", "address bar", "address field", "location bar", "search", "numeric", "numberfield", "number field", "credit card", "card number", "cardnumber", "cvv", "cvc", "security code", "one time", "onetime", "verification code", "social security", "bank account", "routing number", "phone number", "telephone", "amount", "currency"]
        guard !forbidden.contains(where: description.contains) else { return false }
        let tokens = Set(description.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard tokens.isDisjoint(with: ["otp", "ssn", "pin"]) else { return false }
        if let placeholder = placeholder?.trimmingCharacters(in: .whitespacesAndNewlines), !placeholder.isEmpty,
           value?.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder { return false }
        return true
    }
}
