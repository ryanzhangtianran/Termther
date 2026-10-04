import AppKit
import SwiftUI

/// A text file edited in a sheet of the app's own, in the terminal's face
/// and colours: CLAUDE.md, AGENTS.md, ~/.ssh/config.
///
/// The file is read once and written back whole, atomically. If something
/// else changed it in the meantime the save is refused rather than
/// overwriting that change, and the sheet offers to reload.
struct TextFileEditor: View {
    @Environment(Theme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    let url: URL

    /// What the file held when read; the save compares the disk against it.
    @State private var original: String?
    @State private var text = ""
    @State private var position = (line: 1, column: 1)
    @State private var failure: String?
    @State private var changedOnDisk = false
    @State private var confirmingDiscard = false

    private var isEdited: Bool { original != nil && text != original }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if original != nil {
                CodeTextView(text: $text, syntax: Syntax(url), theme: theme) { position = $0 }
            } else {
                Text(failure ?? "")
                    .font(theme.ui(13, weight: .regular))
                    .foregroundStyle(theme.failing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.palette.background.swiftUI)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 440, idealHeight: 560)
        .background(theme.windowBackground)
        .onAppear(perform: load)
        .alert("Discard your changes?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Tile(symbol: "doc.text", size: 26)
            Text(url.lastPathComponent)
                .font(theme.ui(14, weight: .medium))
                .help((url.path as NSString).abbreviatingWithTildeInPath)
            Spacer()
            if isEdited { Chip(title: "Edited", color: theme.waiting) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let failure, original != nil {
                Text(failure)
                    .font(theme.ui(12, weight: .regular))
                    .foregroundStyle(theme.failing)
                    .lineLimit(1)
                if changedOnDisk {
                    Button("Reload", action: load).buttonStyle(.plate)
                }
            } else {
                Text("Line \(position.line), Column \(position.column)")
                    .font(theme.ui(12, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button("Cancel") { if isEdited { confirmingDiscard = true } else { dismiss() } }
                .buttonStyle(.plate)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.plateProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isEdited)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// A file not there yet is an empty one; one that cannot be read as
    /// UTF-8 is not opened at all, so saving cannot replace it with nothing.
    private func load() {
        failure = nil
        changedOnDisk = false
        do {
            let read = try onDisk()
            original = read
            text = read
        } catch {
            original = nil
            failure = "Cannot open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func onDisk() throws -> String {
        FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
    }

    private func save() {
        guard let original, isEdited else { return }
        do {
            guard try onDisk() == original else {
                changedOnDisk = true
                failure = "\(url.lastPathComponent) was changed elsewhere since it was opened."
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            self.original = text
            dismiss()
        } catch {
            failure = "Cannot save: \(error.localizedDescription)"
        }
    }
}

/// What to colour: Markdown for the agents' prompt files, ssh's keywords for
/// its config, nothing for anything else.
enum Syntax {
    case markdown, sshConfig, plain

    init(_ url: URL) {
        let name = url.lastPathComponent.lowercased()
        self = name.hasSuffix(".md") ? .markdown : name == "config" ? .sshConfig : .plain
    }

    /// Each pattern with the ANSI colour it is drawn in; later ones win.
    var rules: [(regex: NSRegularExpression, color: Int)] {
        switch self {
        case .markdown: Self.markdownRules
        case .sshConfig: Self.sshConfigRules
        case .plain: []
        }
    }

    /// Compiled once: the whole file is coloured again on every keystroke.
    private static let markdownRules = compile([
        (#"^\s*([-*+]|\d+\.)\s"#, 5),
        (#"\[[^\]\n]+\]\([^)\n]+\)"#, 12),
        (#"\*\*[^*\n]+\*\*"#, 3),
        (#"`[^`\n]+`"#, 10),
        (#"^#{1,6} .*$"#, 11),
        (#"^```[\s\S]*?^```"#, 10)])
    private static let sshConfigRules = compile([
        (#"^\s*\S+"#, 12),
        (#"^\s*(Host|Match)\b.*$"#, 11),
        (#"#.*$"#, 8)])

    private static func compile(_ rules: [(String, Int)]) -> [(regex: NSRegularExpression, color: Int)] {
        rules.compactMap { pattern, color in
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])).map { ($0, color) }
        }
    }

    @MainActor func highlight(_ storage: NSTextStorage, theme: Theme) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: theme.terminalFace(size: 13),
                               .foregroundColor: theme.palette.foreground.swiftUI.nsColor], range: whole)
        for rule in rules {
            let color = theme.ansi(rule.color).nsColor
            for match in rule.regex.matches(in: storage.string, range: whole) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        storage.endEditing()
    }
}

/// An `NSTextView` with line numbers: SwiftUI's own editor has neither a
/// gutter nor a way to colour what is typed.
private struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let syntax: Syntax
    let theme: Theme
    let moved: ((line: Int, column: Int)) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 12)
        view.backgroundColor = theme.palette.background.swiftUI.nsColor
        view.insertionPointColor = theme.palette.cursor.swiftUI.nsColor
        view.selectedTextAttributes = [.backgroundColor: theme.ansi(4).opacity(0.35).nsColor]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: theme.terminalFace(size: 13), .paragraphStyle: paragraph,
                                 .foregroundColor: theme.palette.foreground.swiftUI.nsColor]
        view.string = text
        if let storage = view.textStorage {
            syntax.highlight(storage, theme: theme)
            storage.addAttribute(.paragraphStyle, value: paragraph,
                                 range: NSRange(location: 0, length: storage.length))
        }
        scroll.backgroundColor = view.backgroundColor
        scroll.drawsBackground = true
        let ruler = LineNumberRuler(textView: view, theme: theme)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.ruler = ruler
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Only a reload from outside replaces the text; typing already
        // matches it, and resetting would throw away the undo stack.
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        if let storage = view.textStorage { syntax.highlight(storage, theme: theme) }
        context.coordinator.ruler?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeTextView
        weak var ruler: NSRulerView?

        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            if let storage = view.textStorage {
                let selection = view.selectedRanges
                parent.syntax.highlight(storage, theme: parent.theme)
                storage.addAttribute(.paragraphStyle, value: view.defaultParagraphStyle ?? .default,
                                     range: NSRange(location: 0, length: storage.length))
                view.selectedRanges = selection
            }
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let text = view.string as NSString
            let location = min(view.selectedRange().location, text.length)
            let before = text.substring(to: location)
            let line = lineNumber(at: location, in: text)
            let column = location - (before.range(of: "\n", options: .backwards).map {
                before.distance(from: before.startIndex, to: $0.upperBound) } ?? 0) + 1
            parent.moved((line, column))
        }
    }
}

/// The gutter: each line's number beside its first fragment, dim, right
/// aligned against the text.
private final class LineNumberRuler: NSRulerView {
    private let theme: Theme

    init(textView: NSTextView, theme: Theme) {
        self.theme = theme
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // Not clipped by default since macOS 14: a number for a line
        // scrolled just past the edge was drawn over the footer below and
        // stayed there.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used from a nib") }

    /// All of it drawn here: the ruler's own drawing adds a separator line
    /// down its edge.
    override func draw(_ dirtyRect: NSRect) {
        theme.palette.background.swiftUI.nsColor.setFill()
        bounds.fill()
        guard let view = clientView as? NSTextView, let layout = view.layoutManager,
              let container = view.textContainer else { return }
        let text = view.string as NSString
        let face = theme.terminalFace(size: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: theme.ansi(8).nsColor]
        let visible = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let first = layout.characterIndexForGlyph(at: visible.location)
        var number = lineNumber(at: first, in: text)
        var index = (text.lineRange(for: NSRange(location: first, length: 0))).location
        let end = layout.characterIndexForGlyph(at: NSMaxRange(visible))

        /// On the line's baseline, so the number sits level with its text.
        func draw(_ number: Int, baseline: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: baseline + view.textContainerInset.height), from: view)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: point.y - face.ascender),
                       withAttributes: attributes)
        }

        // Where the baseline sits within a line: the same for every line,
        // since the face and spacing are.
        var offset = face.ascender
        while index <= end && index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: index)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // A line that is only its newline reports that glyph's place,
            // which is not where text would sit; it keeps the last one.
            if line.length > 1 || text.character(at: index) != 10 {
                offset = layout.location(forGlyphAt: glyph).y
            }
            draw(number, baseline: fragment.minY + offset)
            number += 1
            index = NSMaxRange(line)
        }
        // The empty line after a final newline, or in an empty file.
        if index >= text.length, text.length == 0 || text.hasSuffix("\n") {
            draw(number, baseline: layout.extraLineFragmentRect.minY + offset)
        }
    }
}

/// The number of the line `location` is on: one more than the newlines
/// before it, counted by the string's own search rather than character by
/// character, as the caret and the gutter ask on every move and redraw. A
/// "\r\n" is not counted, as it was not when this counted Characters.
func lineNumber(at location: Int, in text: NSString) -> Int {
    var number = 1
    var from = 0
    while true {
        let found = text.range(of: "\n", options: .literal, range: NSRange(location: from, length: location - from))
        guard found.location != NSNotFound else { return number }
        if found.location == 0 || text.character(at: found.location - 1) != 13 { number += 1 }
        from = found.location + 1
    }
}
