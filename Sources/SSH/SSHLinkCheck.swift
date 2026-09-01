import CSSH2

public enum SSHLinkCheck {
    /// The libssh2 the package actually linked against.
    public static var libssh2Version: String {
        String(cString: libssh2_version(0))
    }
}
