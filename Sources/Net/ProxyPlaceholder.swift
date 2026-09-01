import Foundation

/// Addresses that only exist inside a local TUN proxy.
///
/// Surge, Clash and sing-box answer every DNS lookup with an address from a
/// reserved range and route it through their own interface. Two consequences,
/// both of which have cost real time here:
///
/// * A hostname that does not exist still resolves, so a typo fails later as
///   a connection that goes nowhere rather than as "no such host".
/// * An address like this is meaningless outside the proxy, so anything that
///   pins itself to a physical interface must pin its resolver too -- or it
///   will dial a placeholder from a socket that has no idea what it means.
public enum ProxyPlaceholder {
    /// 198.18.0.0/15 is the benchmarking range Surge and Clash borrow for
    /// this; sing-box hands out from 240.0.0.0/4.
    public static func matches(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return (octets[0] == 198 && (octets[1] == 18 || octets[1] == 19))
            || octets[0] >= 240
    }
}
