import Testing
@testable import Core

/// Turning "request denied" into something actionable.
///
/// sshd answers a forward request with a bare yes or no -- the protocol has no
/// field for a reason -- so libssh2 can only say "denied". The three causes
/// need three different responses from the user, and only the server knows
/// which one applies.
struct ForwardDiagnosisTests {
    private func output(listeners: String, config: String) -> String {
        "--listeners\n\(listeners)\n--config\n\(config)\n--end\n"
    }

    @Test("a port already listening is named as the likely cause")
    func portInUse() {
        let text = ForwardDiagnosis.interpret(
            output(listeners: "LISTEN 0 128 127.0.0.1:16152 0.0.0.0:*", config: ""),
            port: 16152)
        #expect(text.contains("already in use"))
        // It resolves itself, and saying so is the difference between waiting
        // and going to change a server config for no reason.
        #expect(text.contains("retried"))
    }

    @Test("forwarding switched off entirely is called out as a server change")
    func forwardingDisabled() {
        let text = ForwardDiagnosis.interpret(
            output(listeners: "", config: "AllowTcpForwarding no"), port: 16152)
        #expect(text.contains("AllowTcpForwarding no"))
        #expect(text.contains("change on"))
    }

    @Test("local-only forwarding is distinguished from none at all")
    func forwardingLocalOnly() {
        // The trap: -L and -D work, so everything looks fine until a reverse
        // forward is tried.
        let text = ForwardDiagnosis.interpret(
            output(listeners: "", config: "AllowTcpForwarding local"), port: 16152)
        #expect(text.contains("not reverse"))
        #expect(text.contains("AllowTcpForwarding yes"))
    }

    @Test("a listener wins over a permissive config")
    func listenerTakesPrecedence() {
        // Both facts present: the port being taken is the one that explains a
        // denial, and the one that goes away on its own.
        let text = ForwardDiagnosis.interpret(
            output(listeners: "LISTEN 0 128 127.0.0.1:16152 0.0.0.0:*",
                   config: "AllowTcpForwarding yes"), port: 16152)
        #expect(text.contains("already in use"))
    }

    @Test("finding nothing points at the key's own options")
    func nothingFound() {
        let text = ForwardDiagnosis.interpret(output(listeners: "", config: ""), port: 16152)
        // no-port-forwarding lives in authorized_keys, which is not something
        // the checks above can see.
        #expect(text.contains("authorized_keys"))
        #expect(text.contains("no-port-forwarding"))
    }

    @Test("the script asks about the port it was given")
    func scriptTargetsThePort() {
        let script = ForwardDiagnosis.script(port: 16152)
        #expect(script.contains("16152"))
        // Both spellings, because a server has one or the other.
        #expect(script.contains("ss -H -tln"))
        #expect(script.contains("netstat"))
        #expect(script.contains("AllowTcpForwarding"))
    }
}

/// Taking back a port a dead session of ours is still holding.
///
/// The clean path already cancels a listener on disconnect -- but a cancel is
/// a message, and the cases that strand a listener are exactly the ones where
/// there is no longer a wire to send it on: the network changed, or the app
/// died. sshd does not probe its clients by default, so what it leaves behind
/// sits there for hours.
struct ReclaimTests {
    @Test("a stale sshd listener is taken back")
    func reclaims() {
        #expect(ForwardDiagnosis.readOutcome("RESULT reclaimed 4821\n") == .reclaimed)
    }

    @Test("nothing holding the port is not an error")
    func nothingThere() {
        #expect(ForwardDiagnosis.readOutcome("RESULT none\n") == .nothingToReclaim)
    }

    @Test("somebody else's service is named and left alone")
    func leavesOtherProcesses() {
        // The guard that matters: a port we want is not a port we own, and
        // killing a real service to free it would be indefensible.
        let outcome = ForwardDiagnosis.readOutcome("RESULT other nginx (912)\n")
        #expect(outcome == .notOurs("nginx (912)"))
    }

    @Test("a refusal to kill is reported rather than read as success")
    func killFailure() {
        guard case .failed = ForwardDiagnosis.readOutcome("RESULT failed cannot kill 9\n")
        else { Issue.record("expected a failure"); return }
    }

    @Test("silence is a failure, not a quiet success")
    func noAnswer() {
        guard case .failed = ForwardDiagnosis.readOutcome("") else {
            Issue.record("expected a failure"); return
        }
    }

    @Test("a listener this account cannot see is reported as needing privilege")
    func hiddenHolder() {
        let outcome = ForwardDiagnosis.readOutcome("RESULT hidden\n")
        #expect(outcome == .needsPrivilege)
        // And it says the one command that fixes it, because "denied" with no
        // next step is what made this take all afternoon.
        let advice = outcome.advice(port: 16152) ?? ""
        #expect(advice.contains("sudo fuser -k 16152/tcp"))
    }

    @Test("the script looks for the holder three ways")
    func triesEveryLookup() {
        let script = ForwardDiagnosis.reclaimScript(port: 16152)
        // ss -p is the one that fails here: it maps sockets to processes
        // through /proc and shows nothing for another login's listener.
        #expect(script.contains("ss -H -tlnp"))
        #expect(script.contains("lsof -ti"))
        #expect(script.contains("fuser"))
    }

    @Test("a port that is free is told apart from one held invisibly")
    func freeIsNotHidden() {
        // Same empty lookup, opposite meanings: nothing there means the
        // refusal was about policy, something unseen means it was about the
        // port.
        #expect(ForwardDiagnosis.readOutcome("RESULT none\n") == .nothingToReclaim)
        #expect(ForwardDiagnosis.readOutcome("RESULT hidden\n") == .needsPrivilege)
    }

    @Test("the script never kills the session running it")
    func neverKillsItself() {
        let script = ForwardDiagnosis.reclaimScript(port: 16152)
        // $PPID is the sshd serving this very command.
        #expect(script.contains("mine=$PPID"))
        #expect(script.contains("[ \"$pid\" = \"$mine\" ]"))
        // And only ever an sshd: anything else on the port is a real service.
        #expect(script.contains("*sshd*"))
    }
}
