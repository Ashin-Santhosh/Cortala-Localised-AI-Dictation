import Foundation
import Testing
@testable import JustWisper

struct PasteDestinationTests {
    @Test func keyboardEditableFieldsDoNotRequireWritableValue() {
        #expect(PasteFieldPolicy.allows(role: "AXTextArea", secure: false, enabled: true, editable: nil, valueSettable: false, hasSelectionRange: true))
        #expect(!PasteFieldPolicy.allows(role: "AXTextArea", secure: false, enabled: true, editable: false, valueSettable: false, hasSelectionRange: true))
        #expect(!PasteFieldPolicy.allows(role: "AXTextField", secure: true, enabled: true, editable: true, valueSettable: true, hasSelectionRange: true))
        #expect(!PasteFieldPolicy.allows(role: "AXTextField", secure: false, enabled: false, editable: true, valueSettable: true, hasSelectionRange: true))
        #expect(!PasteFieldPolicy.allows(role: "AXStaticText", secure: false, enabled: true, editable: nil, valueSettable: false, hasSelectionRange: true))
    }

    private var field: PasteDestinationFingerprint {
        .init(role: "AXTextArea", identifier: "composer", placeholder: nil, contentDigest: "digest", selection: NSRange(location: 0, length: 0), frame: CGRect(x: 10, y: 20, width: 300, height: 100))
    }
    @Test func unchangedRecreatedEditorIsAccepted() {
        #expect(field.permitsReplacement(field, sameWindow: true, sameParent: true))
    }
    @Test func differentWindowOrParentIsRejected() {
        #expect(!field.permitsReplacement(field, sameWindow: false, sameParent: true))
        #expect(!field.permitsReplacement(field, sameWindow: true, sameParent: false))
    }
    @Test func editsCursorMovementAndDifferentFieldsAreRejected() {
        var changed = field
        changed.contentDigest = "changed"
        #expect(!field.permitsReplacement(changed, sameWindow: true, sameParent: true))
        changed = field; changed.selection.location = 1
        #expect(!field.permitsReplacement(changed, sameWindow: true, sameParent: true))
        changed = field; changed.identifier = "other"
        #expect(!field.permitsReplacement(changed, sameWindow: true, sameParent: true))
        changed = field; changed.frame.origin.x += 1
        #expect(!field.permitsReplacement(changed, sameWindow: true, sameParent: true))
    }
}
