import Foundation
import SSH

/// Why a server refused to listen.
///
/// `tcpip-forward` is answered by sshd with a bare yes or no -- the protocol
/// carries no reason -- so libssh2 can only report "request denied". That is
/// true and useless: the three causes need three different answers, and
/// telling them apart means asking the server, which is worth doing while
/// there is still an authenticated session in hand.
public enum ForwardDiagnosis {
    /// Asks the server what would explain a refusal on this port.
    public static func explain(port: Int, over session: SSHSession) async -> String {
        guard let result = try? await session.exec(script(port: port)) else {
            return "The server refused the request and would not say why."
        }
        return interpret(result.stdout, port: port)
    }

    /// Two questions: is the port taken, and is this kind of forwarding
    /// allowed at all. Written for POSIX sh with everything optional, because
    /// this runs on whatever the server happens to be.
    static func script(port: Int) -> String {
        """
        echo "--listeners"
        (ss -H -tln 2>/dev/null || netstat -an 2>/dev/null) \
            | grep -E "[.:]\(port)[^0-9]" | head -3
        echo "--config"
        grep -Ei '^[[:space:]]*(AllowTcpForwarding|PermitListen|GatewayPorts)' \
            /etc/ssh/sshd_config 2>/dev/null | head -5
        echo "--end"
        """
    }

    /// Turns the two answers into the one sentence that says what to do.
    static func interpret(_ output: String, port: Int) -> String {
        let listeners = section(output, "--listeners", until: "--config")
        let config = section(output, "--config", until: "--end")

        // Read in this order deliberately. A denial with the port already
        // taken is almost always a leftover listener from a dropped session,
        // and that resolves itself; a policy denial never does.
        if !listeners.isEmpty {
            return "Port \(port) is already in use on the server -- most likely a "
                + "listener left behind by a connection that dropped. It is retried "
                + "until the server lets go. Still there: \(listeners)"
        }

        let denies = config.lowercased()
        if denies.contains("allowtcpforwarding no") {
            return "The server's sshd is configured with AllowTcpForwarding no, so "
                + "no forwarding of any kind is permitted. This needs a change on "
                + "the server."
        }
        if denies.contains("allowtcpforwarding local") {
            return "The server's sshd is configured with AllowTcpForwarding local, "
                + "which permits local and dynamic forwards but not reverse ones. "
                + "It needs `AllowTcpForwarding yes` (or `remote`) to accept this."
        }
        if denies.contains("permitlisten") {
            return "The server's sshd restricts which ports may be listened on "
                + "(PermitListen), and \(port) is not among them: \(config)"
        }

        // Nothing found is itself informative: the key's own options can carry
        // no-port-forwarding, and those are not in sshd_config.
        return "The server refused the request, and nothing on it explains why: "
            + "port \(port) is free and sshd_config does not forbid forwarding. "
            + "The usual remaining cause is a restriction on the key itself -- a "
            + "`restrict` or `no-port-forwarding` option in front of its line in "
            + "authorized_keys."
    }

    /// Takes back a port held by a dropped session of our own.
    ///
    /// Needed because the wait is otherwise measured in hours: sshd does not
    /// probe its clients by default (`ClientAliveInterval 0`), so a session
    /// whose network vanished sits half-open until TCP keepalive notices --
    /// two hours, by default. Its listener holds the port for that whole time,
    /// and every retry is refused.
    ///
    /// Only an sshd process, and never the one running this command. Anything
    /// else on that port is somebody's actual service and is left alone.
    public static func reclaim(port: Int, over session: SSHSession) async -> Outcome {
        guard let result = try? await session.exec(reclaimScript(port: port)) else {
            return .failed("could not ask the server")
        }
        return readOutcome(result.stdout)
    }

    public enum Outcome: Sendable, Equatable {
        case reclaimed
        /// Held by something that is not a stale session of ours.
        case notOurs(String)
        /// Something is listening, but this account can neither see whose it
        /// is nor end it. Root-owned, which is what a listener left by an
        /// sshd running with privilege separation looks like.
        case needsPrivilege
        case nothingToReclaim
        case failed(String)

        /// What to tell the user, when there is something for them to do.
        public func advice(port: Int) -> String? {
            switch self {
            case .needsPrivilege:
                "Port \(port) is held by a process this account cannot end -- a "
                    + "listener left by a dropped session, owned by root. On the "
                    + "server: sudo fuser -k \(port)/tcp"
            case .notOurs(let what):
                "Port \(port) is held by \(what), which is not a leftover of ours "
                    + "and was left alone. Give the tunnel another port, or stop that."
            default: nil
            }
        }
    }

    static func reclaimScript(port: Int) -> String {
        // Three lookups, because the obvious one is the one that fails here.
        // `ss -p` maps a socket to a process by walking /proc, and it only
        // reports what the caller may see -- a listener left by another login
        // of the same account shows up with no process at all, which is
        // exactly the case worth recovering from. lsof and fuser ask the
        // kernel a different way and find it.
        //
        // $PPID is the sshd serving this very command; killing it would drop
        // the connection asking the question.
        """
        port=\(port)
        mine=$PPID

        pid=$(ss -H -tlnp 2>/dev/null | grep -E "[.:]$port[^0-9]" \
                | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
        [ -z "$pid" ] && pid=$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null | head -1)
        [ -z "$pid" ] && pid=$(fuser "$port/tcp" 2>/dev/null | tr -s ' ' '\\n' \
                | grep -E '^[0-9]+$' | head -1)

        if [ -z "$pid" ]; then
            # Nothing found. Either the port is free, or it is held by a
            # process this account cannot see -- and those are different
            # answers, so check whether anything is listening at all.
            if (ss -H -tln 2>/dev/null || netstat -an 2>/dev/null) \
                 | grep -qE "[.:]$port[^0-9]"; then
                echo "RESULT hidden"
            else
                echo "RESULT none"
            fi
            exit 0
        fi
        if [ "$pid" = "$mine" ]; then echo "RESULT none"; exit 0; fi

        name=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "$name" in
          *sshd*) kill "$pid" 2>/dev/null && echo "RESULT reclaimed $pid" \
                    || echo "RESULT hidden" ;;
          *)      echo "RESULT other $name ($pid)" ;;
        esac
        """
    }

    static func readOutcome(_ output: String) -> Outcome {
        guard let line = output.split(separator: "\n")
            .first(where: { $0.hasPrefix("RESULT ") })?
            .dropFirst("RESULT ".count)
        else { return .failed("the server said nothing") }

        let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
        return switch fields.first {
        case "reclaimed": .reclaimed
        case "none":      .nothingToReclaim
        case "hidden":    .needsPrivilege
        case "other":     .notOurs(fields.count > 1 ? fields[1] : "unknown")
        default:          .failed(fields.count > 1 ? fields[1] : "unknown")
        }
    }

    private static func section(_ output: String, _ start: String, until end: String) -> String {
        guard let from = output.range(of: start), let to = output.range(of: end),
              from.upperBound <= to.lowerBound
        else { return "" }
        return output[from.upperBound..<to.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
