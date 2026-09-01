import Testing
import Net
@testable import App

/// Telling a real address from the one a local proxy invented.
///
/// This exists because a wrong hostname stopped looking like a wrong hostname:
/// with a TUN proxy running, every name resolves -- including names that do
/// not exist -- so the failure arrives as "unreachable" instead of "no such
/// host", and points at the gateway rather than at the typo.
struct PlaceholderAddressTests {
    @Test("the range TUN proxies hand out is recognised")
    func recognisesPlaceholders() {
        // 198.18.0.0/15 is the benchmarking range Surge and Clash borrow.
        #expect(ProxyPlaceholder.matches("198.18.2.24"))
        #expect(ProxyPlaceholder.matches("198.19.255.1"))
        // sing-box hands out from 240.0.0.0/4.
        #expect(ProxyPlaceholder.matches("240.0.0.7"))
    }

    @Test("real addresses are left alone")
    func leavesRealAddressesAlone() {
        #expect(!ProxyPlaceholder.matches("118.143.41.194"))
        #expect(!ProxyPlaceholder.matches("10.7.153.133"))
        #expect(!ProxyPlaceholder.matches("127.0.0.1"))
        // The neighbours of the range, which an off-by-one would swallow.
        #expect(!ProxyPlaceholder.matches("198.17.0.1"))
        #expect(!ProxyPlaceholder.matches("198.20.0.1"))
        #expect(!ProxyPlaceholder.matches("239.255.255.255"))
    }

    @Test("nonsense is not mistaken for a placeholder")
    func rejectsNonsense() {
        #expect(!ProxyPlaceholder.matches(""))
        #expect(!ProxyPlaceholder.matches("not-an-address"))
        #expect(!ProxyPlaceholder.matches("198.18.2"))
    }
}
