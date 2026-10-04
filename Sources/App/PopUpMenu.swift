import AppKit
import SwiftUI

/// A choice from a list: the current value in grey, and beside it a small
/// rounded box with the up and down arrows -- the one look every such choice
/// in the app takes.
///
/// Drawn here, and the list is AppKit's own menu, opened with the current item
/// over the pointer. A SwiftUI menu inside the settings form came out with
/// greyed items that would not pick and a stray checkmark, and a pop-up
/// button's own look could not be matched to the box.
struct PopUpMenu<Value: Hashable>: View {
    typealias Option = (title: String, value: Value)

    @Environment(Theme.self) private var theme
    /// Groups of options, a separator between each.
    let sections: [[Option]]
    @Binding var selection: Value

    init(_ options: [Option], selection: Binding<Value>) {
        self.init(sections: [options], selection: selection)
    }

    init(sections: [[Option]], selection: Binding<Value>) {
        self.sections = sections.filter { !$0.isEmpty }
        _selection = selection
    }

    private var options: [Option] { sections.flatMap { $0 } }

    var body: some View {
        Button(action: show) {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 18, height: 22)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(theme.text.opacity(0.1))
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func show() {
        let menu = NSMenu()
        // The UI's own face, as the label has.
        let plain = NSFont.systemFont(ofSize: 13)
        menu.font = plain.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 13) } ?? plain

        // The tag is the option's place in the flat list; items are added by
        // hand so that two options with one title stay two.
        let target = Target { index in
            if options.indices.contains(index) { selection = options[index].value }
        }
        var index = 0
        var current: NSMenuItem?
        for (number, section) in sections.enumerated() {
            if number > 0 { menu.addItem(.separator()) }
            for option in section {
                let item = NSMenuItem(title: option.title, action: #selector(Target.picked(_:)),
                                      keyEquivalent: "")
                item.target = target
                item.tag = index
                if option.value == selection {
                    item.state = .on
                    current = item
                }
                menu.addItem(item)
                index += 1
            }
        }
        // Modal until it closes, so `target` lives as long as it is needed.
        menu.popUp(positioning: current, at: NSEvent.mouseLocation, in: nil)
    }

    private final class Target: NSObject {
        let pick: (Int) -> Void
        init(_ pick: @escaping (Int) -> Void) { self.pick = pick }
        @objc func picked(_ item: NSMenuItem) { pick(item.tag) }
    }
}
