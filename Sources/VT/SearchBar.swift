import AppKit

/// The find bar over a terminal's corner: the field, "3/12", ‹ › and a
/// close button. It only reports; the view it sits on drives the search.
@MainActor
final class SearchBar: NSVisualEffectView {
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")

    /// The needle changed, as typed.
    var onChange: ((String) -> Void)?
    /// Enter, ⌘G and the arrows: the next match, or with Shift the previous.
    var onStep: ((_ forward: Bool) -> Void)?
    /// Escape, or the close button.
    var onClose: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        // Over the Metal layer, which is a sublayer of the view's own rather
        // than a view's, so the usual subview order says nothing about it.
        layer?.zPosition = 1

        field.delegate = self
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = "Find"
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right

        let stack = NSStackView(views: [field, count,
                                        button("chevron.up", "Previous match", #selector(previous)),
                                        button("chevron.down", "Next match", #selector(next)),
                                        button("xmark", "Close", #selector(close))])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 150),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// "3/12" while a match is selected, "0" when there is none, nothing
    /// while there is no needle.
    func show(index: Int?, of total: Int) {
        count.stringValue = field.stringValue.isEmpty ? ""
            : index.map { "\($0 + 1)/\(total)" } ?? "\(total)"
    }

    private func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = help
        return button
    }

    @objc private func previous() { onStep?(false) }
    @objc private func next() { onStep?(true) }
    @objc private func close() { onClose?() }
}

extension SearchBar: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    /// Enter and Escape, before the field editor acts on them: Escape would
    /// otherwise clear the field, and Enter is the next match -- the previous
    /// with Shift, which the command does not say but the event does.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }
}
