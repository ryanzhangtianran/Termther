import CSSH2
import Foundation

/// Keeping an otherwise silent session alive.
///
/// A session carrying only port forwards can go minutes without a byte, and
/// servers -- and the NAT boxes between them -- drop connections that look
/// idle. The forward then appears to work until the moment something uses it,
/// which is the worst way to find out. A shell session has a person typing on
/// it and needs none of this.
public extension SSHSession {
    /// Asks libssh2 to keep the session warm, and says how often to prod it.
    func enableKeepalive(every seconds: UInt32 = 30) {
        guard let session else { return }
        // want_reply: the server has to answer, so a dead peer is noticed here
        // rather than at the next real write.
        libssh2_keepalive_config(session, 1, seconds)
    }

    /// Sends a keepalive if one is due.
    ///
    /// Returns the seconds until the next one, so a caller can sleep exactly
    /// that long instead of guessing. Nil means the session is gone.
    @discardableResult
    func sendKeepalive() -> Int32? {
        guard let session else { return nil }
        var secondsToNext: Int32 = 0
        let rc = libssh2_keepalive_send(session, &secondsToNext)
        // EAGAIN only means the write did not fit right now; the session is
        // fine and the next attempt carries it.
        if rc < 0 && rc != LIBSSH2_ERROR_EAGAIN { return nil }
        return max(1, secondsToNext)
    }
}
