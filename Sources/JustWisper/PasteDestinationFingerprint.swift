import Foundation

/// A recreated accessibility object must still describe the same unchanged editor.
struct PasteDestinationFingerprint: Equatable {
    var role: String
    var identifier: String?
    var placeholder: String?
    var contentDigest: String
    var selection: NSRange
    var frame: CGRect

    func permitsReplacement(_ current: Self, sameWindow: Bool, sameParent: Bool) -> Bool {
        sameWindow && sameParent && self == current
    }
}

/// Text editors may expose selection without allowing direct AXValue writes.
enum PasteFieldPolicy {
    static func allows(role: String?, secure: Bool, enabled: Bool?, editable: Bool?, valueSettable: Bool, hasSelectionRange: Bool) -> Bool {
        guard !secure, enabled != false,
              let role, ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) else { return false }
        if let editable { return editable }
        return valueSettable || hasSelectionRange
    }
}
