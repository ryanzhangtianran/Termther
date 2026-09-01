import Foundation
import Testing
@testable import Core

@Test("the install script is safe to run twice")
func installScriptIsIdempotent() {
    let script = SSHKeys.installScript(publicKey: "ssh-ed25519 AAAA me@mac")
    // A retry after a dropped connection must not append the key again.
    #expect(script.contains("grep -qxF"))
    // sshd ignores an authorized_keys anyone else can write.
    #expect(script.contains("chmod 700"))
    #expect(script.contains("chmod 600"))
    #expect(script.contains("umask 077"))
    // Fails loudly rather than half-applying.
    #expect(script.hasPrefix("set -e"))
}

@Test("rotating a key removes the one it replaces")
func installScriptReplaces() {
    let script = SSHKeys.installScript(publicKey: "ssh-ed25519 NEW me@mac",
                                       replacing: "ssh-ed25519 OLD me@mac")
    #expect(script.contains("grep -vxF"))
    #expect(script.contains("OLD"))
    // The new key still goes in.
    #expect(script.contains("NEW"))
}

@Test("a key's comment cannot become part of the command")
func installScriptQuotes() {
    // Comments are free text and end up in a shell command; an unquoted one
    // would run whatever it contained.
    let script = SSHKeys.installScript(
        publicKey: "ssh-ed25519 AAAA don't; rm -rf /")
    #expect(script.contains("'\\''"), "the quote should have been escaped")
    #expect(!script.contains("; rm -rf /\n"), "the payload must stay inside quotes")
}

@Test("the pasteable command matches what the script does")
func installCommandIsIdempotentToo() {
    // Used when the app cannot reach the server; running it twice should be
    // as harmless as the script.
    let command = SSHKeys.installCommand(publicKey: "ssh-ed25519 AAAA me@mac")
    #expect(command.contains("grep -qxF"))
    #expect(command.contains("chmod 700"))
    #expect(command.contains("chmod 600"))
}
