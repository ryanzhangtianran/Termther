import Testing
@testable import VT

/// The schemes that ship with the app.
///
/// A palette is data, and data is where a typo hides best: sixteen hex numbers
/// look right whatever they say. These check the properties a scheme has to
/// have to be usable at all, rather than the values, which are somebody's
/// design and not mine to assert.
struct PaletteTests {
    @Test("every built-in scheme has all sixteen ANSI colours")
    func sixteenColours() {
        for palette in Palette.builtIn {
            #expect(palette.ansi.count == 16, "\(palette.name)")
        }
    }

    @Test("names are unique, or one of them cannot be chosen")
    func namesAreUnique() {
        // Settings stores the name and looks it up again; two schemes sharing
        // one means the second is unreachable and the first comes back
        // whichever was picked.
        let names = Palette.builtIn.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("every scheme can be found by the name it stores")
    func lookupRoundTrips() {
        for palette in Palette.builtIn {
            #expect(Palette.named(palette.name) == palette, "\(palette.name)")
        }
    }

    @Test("text is not the same colour as the ground it sits on")
    func foregroundIsLegible() {
        for palette in Palette.builtIn {
            // Not a contrast ratio -- these are hand-tuned schemes and their
            // authors know what they are doing -- but a scheme whose text and
            // background are within a few points of each other is a mistake in
            // transcription, not a choice.
            let distance = abs(Int(palette.foreground.red) - Int(palette.background.red))
                + abs(Int(palette.foreground.green) - Int(palette.background.green))
                + abs(Int(palette.foreground.blue) - Int(palette.background.blue))
            #expect(distance > 120, "\(palette.name) is nearly invisible on itself")
        }
    }

    @Test("the default is the one the app says it is")
    func defaultIsKanagawa() {
        #expect(Palette.builtIn.first == .kanagawaWave)
    }

    @Test("all four Catppuccin flavours are there")
    func catppuccinIsComplete() {
        // One theme at four levels of contrast; shipping three of them is the
        // kind of gap nobody notices until they want the missing one.
        let flavours = Palette.builtIn.filter { $0.name.hasPrefix("Catppuccin") }
        #expect(flavours.count == 4)
        #expect(flavours.contains(.catppuccinLatte))   // the light one
    }

    @Test("the 256-colour table is the sixteen plus the standard rest")
    func fullTable() {
        for palette in Palette.builtIn {
            #expect(palette.full256.count == 256, "\(palette.name)")
            #expect(Array(palette.full256.prefix(16)) == palette.ansi)
        }
    }
}
