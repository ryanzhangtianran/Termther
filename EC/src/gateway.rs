//! Everything that talks to the gateway itself, as opposed to through it.
//!
//! The flow runs in this order. `/por/login_auth.csp` returns a session ID
//! (TWFID) and an RSA key. `/por/login_psw.csp`, plus `/por/login_token.csp`
//! for a TOTP second factor, authorises that session. The next handshake binds
//! the TWFID to a TLS session ID, and the two together form the token. The
//! token is exchanged for a tunnel address. From then on, two TLS streams
//! carry raw IP packets, one in each direction.

use crate::stack::dns;
use crate::tls::{hmac, rsa_encrypt, Hello, Tls};
use crate::{Error, Result};
use rsa::{BigUint, RsaPublicKey};
use sha1::Sha1;
use socket2::{Domain, SockRef, Socket, TcpKeepalive, Type};
use std::collections::{BTreeSet, HashMap};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream, ToSocketAddrs, UdpSocket};
use std::time::Duration;

/// How the client's own sockets reach the gateway.
///
/// These exist because of local TUN proxies. Clash, sing-box and friends take
/// the default route and answer DNS with addresses in 198.18.0.0/15, so
/// without pinning an interface and a resolver the client dials the proxy
/// instead of the gateway and fails during the TLS handshake -- which reads,
/// misleadingly, as the gateway being down.
#[derive(Clone, Default)]
pub struct Underlay {
    /// Physical interface to bind to, e.g. "eth0".
    pub interface: Option<String>,
    /// Resolver for the gateway's own hostname, e.g. "10.90.63.2".
    pub dns: Option<String>,
}

#[derive(Clone)]
pub struct Gateway {
    pub host: String,
    pub port: u16,
    pub underlay: Underlay,
    twfid: String,
    token: Vec<u8>,
    pub address: [u8; 4],
}

pub struct Response {
    pub status: u16,
    pub body: String,
}

impl Gateway {
    pub fn new(text: &str, underlay: Underlay) -> Gateway {
        let text = text.split_once("://").map_or(text, |(_, rest)| rest);
        let text = text.split('/').next().unwrap_or_default();
        let (host, port) = text
            .rsplit_once(':')
            .and_then(|(host, port)| Some((host, port.parse().ok()?)))
            .unwrap_or((text, 443));
        Gateway { host: host.into(), port, underlay, twfid: String::new(), token: vec![], address: [0; 4] }
    }

    fn authority(&self) -> String {
        if self.port == 443 { self.host.clone() } else { format!("{}:{}", self.host, self.port) }
    }

    /// Authorises a fresh TWFID with a username, password and optional TOTP secret.
    pub fn login(&mut self, username: &str, password: &str, totp_secret: Option<&str>) -> Result<()> {
        let auth = self.request("GET", "/por/login_auth.csp?apiversion=1", None)?.body;
        let (Some(twfid), Some(modulus)) = (field("TwfID", &auth), field("RSA_ENCRYPT_KEY", &auth)) else {
            bail!("unexpected login_auth reply: {}", prefix(&auth));
        };
        self.twfid = twfid.into();
        if field("RndImg", &auth) == Some("1") {
            return Err(unsupported("a picture captcha"));
        }

        let csrf = field("CSRF_RAND_CODE", &auth).unwrap_or_default();
        let secret = if csrf.is_empty() { password.to_string() } else { format!("{password}_{csrf}") };
        let exponent: u64 = field("RSA_ENCRYPT_EXP", &auth).and_then(|e| e.parse().ok()).unwrap_or(65537);
        let key = BigUint::parse_bytes(modulus.as_bytes(), 16)
            .and_then(|n| RsaPublicKey::new(n, BigUint::from(exponent)).ok())
            .ok_or("RSA: the gateway sent an unusable key")?;
        let encrypted = hex(&rsa_encrypt(&key, secret.as_bytes())?);

        let reply = self
            .request("POST", "/por/login_psw.csp?anti_replay=1&encrypt=1&type=cs", Some(&[
                ("svpn_rand_code", ""), ("mitm", ""), ("svpn_req_randcode", csrf),
                ("svpn_name", username), ("svpn_password", &encrypted),
            ]))?
            .body;

        let next = field("NextAuth", &reply);
        if reply.contains("<NextService>auth/token</NextService>") || next == Some("7") {
            let Some(secret) = totp_secret.filter(|s| !s.is_empty()) else {
                bail!("the account needs a TOTP code, and no TOTP secret was given");
            };
            let unix = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
            return self.login_totp(&totp(secret, unix)?);
        }
        if reply.contains("<NextService>auth/sms</NextService>") || next == Some("2") {
            return Err(unsupported("an SMS code"));
        }
        match next {
            Some("0") => return Err(unsupported("a client certificate")),
            Some(other) if other != "-1" => return Err(unsupported(&format!("second factor {other}"))),
            _ => {}
        }
        if field("Result", &reply) != Some("1") {
            bail!("{}", field("Message", &reply).map_or_else(|| prefix(&reply), String::from));
        }
        if let Some(updated) = field("TwfID", &reply) {
            self.twfid = updated.into();
        }
        Ok(())
    }

    fn login_totp(&mut self, code: &str) -> Result<()> {
        let reply = self.request("POST", "/por/login_token.csp", Some(&[("svpn_inputtoken", code)]))?.body;
        match field("TwfID", &reply) {
            Some(updated) if reply.contains("Totp auth succ") => {
                self.twfid = updated.into();
                Ok(())
            }
            _ => bail!("TOTP rejected: {}", field("Message", &reply).map_or_else(|| prefix(&reply), String::from)),
        }
    }

    /// Binds the TWFID to a TLS session. The token is the first 31 hex digits
    /// of that session's ID, a NUL, then the TWFID.
    pub fn request_token(&mut self) -> Result<()> {
        let mut tls = self.connect(Hello::Portal { server_name: &self.host })?;
        let (authority, cookie) = (self.authority(), format!("Cookie: TWFID={}\r\n\r\n", self.twfid));
        tls.write(format!(
            "GET /por/conf.csp HTTP/1.1\r\nHost: {authority}\r\n{cookie}GET /por/rclist.csp HTTP/1.1\r\nHost: {authority}\r\n{cookie}"
        ).as_bytes())?;
        tls.read()?;

        let session = hex(&tls.session_id);
        let mut token = session.as_bytes()[..session.len().min(31)].to_vec();
        token.push(0);
        token.extend(self.twfid.as_bytes());
        if session.len() < 31 || token.len() != 48 {
            bail!("cannot form a tunnel token (session ID {} bytes, TWFID {} characters)", tls.session_id.len(), self.twfid.len());
        }
        self.token = token;
        Ok(())
    }

    /// Exchanges the token for a tunnel address. The connection that asked must
    /// stay open for the tunnel's lifetime, so it is returned.
    pub fn request_address(&mut self) -> Result<Tls> {
        let mut tls = self.connect(Hello::Tunnel)?;
        tls.write(&[&[0, 0, 0, 0][..], &self.token, &[0; 8], &[0xFF; 4]].concat())?;
        let reply = tls.read()?;
        if reply.len() < 8 || reply[0] != 0 {
            bail!("the gateway refused a tunnel address");
        }
        self.address.copy_from_slice(&reply[4..8]);
        Ok(tls)
    }

    /// One direction of the packet tunnel. The command byte is 5 to send and 6 to receive.
    ///
    /// Keepalive probes after thirty idle seconds make a dead path, such as a
    /// NAT mapping that expired, fail within a minute instead of blocking a
    /// read forever, so the stream is reopened.
    pub fn open_tunnel(&self, sending: bool) -> Result<Tls> {
        let mut tls = self.connect(Hello::Tunnel)?;
        let probes = TcpKeepalive::new().with_time(Duration::from_secs(30)).with_interval(Duration::from_secs(10)).with_retries(3);
        SockRef::from(tls.socket()).set_tcp_keepalive(&probes)?;
        let mut address = self.address;
        address.reverse();
        tls.write(&[&[if sending { 5 } else { 6 }, 0, 0, 0][..], &self.token, &[0; 8], &address].concat())?;
        match (sending, tls.read()?.first()) {
            (true, Some(0x02)) | (false, Some(0x01)) => Ok(tls),
            (_, Some(0x08)) => bail!("the gateway ended the session"),
            (_, Some(0x05..=0x07 | 0x09)) => bail!("the gateway is busy; try again"),
            (_, reply) => bail!("unexpected tunnel reply {reply:?}"),
        }
    }

    /// Keeps the session from being closed as idle, as the official client
    /// does. Returns false if the gateway doesn't support it.
    pub fn update_session(&self) -> bool {
        let path = format!("/por/update_session.csp?apiversion=1&twfid={}", self.twfid);
        self.request("GET", &path, None).map_or(true, |r| r.status != 404)
    }

    pub fn resources(&self) -> Result<Routing> {
        Ok(Routing::parse(&self.request("GET", "/por/rclist.csp", None)?.body))
    }

    /// A TLS connection to the gateway on the physical network.
    pub fn connect(&self, hello: Hello) -> Result<Tls> {
        Tls::handshake(self.dial()?, hello)
    }

    pub fn request(&self, method: &str, path: &str, form: Option<&[(&str, &str)]>) -> Result<Response> {
        let mut tls = self.connect(Hello::Portal { server_name: &self.host })?;
        let mut head = format!(
            "{method} {path} HTTP/1.1\r\nHost: {}\r\nUser-Agent: EasyConnect_windows\r\nConnection: close\r\n",
            self.authority()
        );
        if !self.twfid.is_empty() {
            head += &format!("Cookie: TWFID={}\r\n", self.twfid);
        }
        let body = form
            .map(|f| f.iter().map(|(k, v)| format!("{k}={}", percent(v))).collect::<Vec<_>>().join("&"))
            .unwrap_or_default();
        if form.is_some() {
            head += &format!("Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {}\r\n", body.len());
        }
        tls.write(format!("{head}\r\n{body}").as_bytes())?;

        let mut raw = vec![];
        loop {
            if let Some(response) = parse_http(&raw, false) {
                return Ok(response);
            }
            match tls.read() {
                Ok(bytes) => raw.extend(bytes),
                Err(Error::Closed) => break,
                Err(e) => return Err(e),
            }
        }
        parse_http(&raw, true).ok_or_else(|| format!("{path}: the gateway closed the connection without replying").into())
    }

    fn dial(&self) -> Result<TcpStream> {
        let interface = self.underlay.interface.as_deref();
        let ip = match (self.host.parse::<Ipv4Addr>(), &self.underlay.dns) {
            (Ok(ip), _) => ip,
            (_, Some(server)) => lookup(&self.host, server, interface)?,
            _ => (self.host.as_str(), self.port)
                .to_socket_addrs()
                .map_err(|e| format!("resolve {}: {e}", self.host))?
                .find_map(|a| match a.ip() { std::net::IpAddr::V4(ip) => Some(ip), _ => None })
                .ok_or_else(|| format!("resolve {}: no IPv4 address", self.host))?,
        };
        let socket = socket(Type::STREAM, interface)?;
        // A deadline, so an unreachable gateway fails in ten seconds instead of the kernel's seventy-five.
        socket
            .connect_timeout(&SocketAddrV4::new(ip, self.port).into(), Duration::from_secs(10))
            .map_err(|e| format!("connect {}:{}: {e}", self.host, self.port))?;
        socket.set_nodelay(true)?;
        let stream = TcpStream::from(socket);
        stream.set_read_timeout(Some(Duration::from_secs(15)))?;
        stream.set_write_timeout(Some(Duration::from_secs(15)))?;
        Ok(stream)
    }
}

pub enum Probe {
    EasyConnect(String),
    SomethingElse(String),
    Unreachable(String),
}

/// Asks a gateway what it is, without credentials.
///
/// A Sangfor EasyConnect gateway answers `/por/login_auth.csp` with XML and a
/// TWFID cookie. Anything else is most likely aTrust, Sangfor's newer product,
/// which speaks a different protocol.
pub fn probe(gateway: &str, underlay: Underlay) -> Probe {
    let response = match Gateway::new(gateway, underlay).request("GET", "/por/login_auth.csp?apiversion=1", None) {
        Ok(response) => response,
        Err(e) => return Probe::Unreachable(e.to_string()),
    };
    let text: String = response.body.chars().take(512).collect();
    let text = text.trim();
    let text = if text.chars().count() > 240 { format!("{}...", text.chars().take(240).collect::<String>()) } else { text.into() };
    let detail = format!("HTTP {} | {text}", response.status);
    let lower = text.to_lowercase();
    if lower.contains("<auth") || lower.contains("twfid") { Probe::EasyConnect(detail) } else { Probe::SomethingElse(detail) }
}

fn unsupported(what: &str) -> Error {
    format!("the gateway asks for {what}, which termther-ec does not support").into()
}

/// A socket, bound to a physical interface if one is named.
///
/// On Linux this is SO_BINDTODEVICE, which needs CAP_NET_RAW on kernels
/// before 5.7.
fn socket(kind: Type, interface: Option<&str>) -> Result<Socket> {
    let socket = Socket::new(Domain::IPV4, kind, None)?;
    // Inside the app nothing ignores SIGPIPE, so a write to a closed socket would end the process.
    #[cfg(target_vendor = "apple")]
    socket.set_nosigpipe(true)?;
    if let Some(name) = interface.filter(|n| !n.is_empty()) {
        #[cfg(target_os = "linux")]
        let bound = socket.bind_device(Some(name.as_bytes()));
        #[cfg(target_os = "macos")]
        let bound = {
            let name = std::ffi::CString::new(name).unwrap_or_default();
            match std::num::NonZeroU32::new(unsafe { libc::if_nametoindex(name.as_ptr()) }) {
                Some(index) => socket.bind_device_by_index_v4(Some(index)),
                None => Err(std::io::Error::other("no such interface")),
            }
        };
        bound.map_err(|e| format!("cannot bind to {name}: {e}"))?;
    }
    Ok(socket)
}

/// Resolves over the physical network, which is how the gateway's own name is
/// looked up when a TUN proxy owns the system resolver.
fn lookup(name: &str, server: &str, interface: Option<&str>) -> Result<Ipv4Addr> {
    let server: Ipv4Addr = server.parse().map_err(|_| format!("bad DNS server {server}"))?;
    let socket = UdpSocket::from(socket(Type::DGRAM, interface)?);
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    let id = rand::random();
    let query = dns::query(name, id);
    for _ in 0..2 {
        let _ = socket.send_to(&query, (server, 53));
        let mut reply = [0; 1500];
        if let Some(found) = socket.recv(&mut reply).ok().and_then(|n| dns::first_address(&reply[..n], id)) {
            return Ok(found);
        }
    }
    bail!("cannot resolve {name} with {server}")
}

/// The text of `<tag>...</tag>`. The gateway's replies are XML-shaped, but not
/// reliably enough to hand to a parser.
fn field<'a>(tag: &str, text: &'a str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&format!("</{tag}>"))?;
    Some(&text[start..start + end])
}

fn prefix(text: &str) -> String {
    text.chars().take(200).collect()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn percent(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// A complete response in `raw`, or None while more is needed. `at_end`
/// accepts a body that ends where the connection did.
pub fn parse_http(raw: &[u8], at_end: bool) -> Option<Response> {
    let split = find(raw, b"\r\n\r\n")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_lowercase();
    let mut lines = head.split("\r\n");
    let status = lines.next()?.split(' ').nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    let headers: HashMap<&str, &str> = lines.filter_map(|l| l.split_once(':')).map(|(k, v)| (k, v.trim())).collect();
    let mut body = &raw[split + 4..];

    let decoded;
    if headers.get("transfer-encoding").is_some_and(|v| v.contains("chunked")) {
        let mut out = vec![];
        loop {
            let end = find(body, b"\r\n")?;
            let size = String::from_utf8_lossy(&body[..end]);
            let size = usize::from_str_radix(size.split(';').next()?.trim(), 16).ok()?;
            if size == 0 {
                break;
            }
            // A size too large to add up is never complete; the caller's read ends in an error.
            let next = size.checked_add(end + 4).filter(|&next| next <= body.len())?;
            out.extend(&body[end + 2..next - 2]);
            body = &body[next..];
        }
        decoded = out;
        body = &decoded;
    } else if let Some(length) = headers.get("content-length").and_then(|v| v.parse().ok()) {
        if body.len() < length {
            return None;
        }
        body = &body[..length];
    } else if !at_end {
        return None;
    }
    Some(Response { status, body: String::from_utf8_lossy(body).into_owned() })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// RFC 6238: six digits, thirty-second steps, HMAC-SHA1.
pub fn totp(secret: &str, unix: u64) -> Result<String> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let (mut bits, mut value, mut key) = (0, 0u32, vec![]);
    for c in secret.to_uppercase().bytes().filter(|&c| c != b'=' && c != b' ') {
        let index = ALPHABET.iter().position(|&a| a == c).ok_or("the TOTP secret is not base32")?;
        value = (value << 5 | index as u32) & 0xFFFF;
        bits += 5;
        if bits >= 8 {
            key.push((value >> (bits - 8)) as u8);
            bits -= 8;
        }
    }
    let mac = hmac::<Sha1>(&key, &(unix / 30).to_be_bytes());
    let o = (mac[19] & 0x0F) as usize;
    let number = u32::from_be_bytes([mac[o] & 0x7F, mac[o + 1], mac[o + 2], mac[o + 3]]) % 1_000_000;
    Ok(format!("{number:06}"))
}

/// What the gateway will route for this session. Traffic outside the list is
/// silently dropped instead of refused, which looks like a hang.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Routing {
    pub ip: Vec<Range>,
    pub domains: Vec<String>,
    pub dns: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Range {
    pub from: String,
    pub to: String,
    pub port_min: u16,
    pub port_max: u16,
    pub protocol: &'static str,
}

impl Routing {
    /// Parses `/por/rclist.csp`. Resources of type 1 and 2 are the routed
    /// ones. Hosts and ports are parallel lists separated by `;`, and ranges
    /// use `~`.
    pub fn parse(rclist: &str) -> Routing {
        let is_ipv4 = |s: &str| s.parse::<Ipv4Addr>().is_ok();
        let mut routing = Routing::default();
        let mut domains = BTreeSet::new();
        for rc in elements(rclist, "Rc") {
            if !matches!(rc.get("type").map(String::as_str), Some("1" | "2")) {
                continue;
            }
            let protocol = match rc.get("proto").map(String::as_str) {
                Some("-1") => "all",
                Some("0") => "tcp",
                Some("1") => "udp",
                Some("2") => "icmp",
                _ => "",
            };
            let (Some(hosts), Some(ports)) = (rc.get("host"), rc.get("port")) else { continue };
            let (hosts, ports): (Vec<_>, Vec<_>) = (hosts.split(';').collect(), ports.split(';').collect());
            if hosts.len() != ports.len() {
                continue;
            }
            for (host, range) in hosts.into_iter().zip(ports) {
                let bounds: Vec<u16> = range.split('~').filter_map(|p| p.parse().ok()).collect();
                let &[mut port_min, mut port_max] = &bounds[..] else { continue };
                if host.contains('~') {
                    if let Some((from, to)) = host.split_once('~').filter(|(a, b)| is_ipv4(a) && is_ipv4(b)) {
                        routing.ip.push(Range { from: from.into(), to: to.into(), port_min, port_max, protocol });
                    }
                    continue;
                }
                let name = host.rsplit("//").next().unwrap_or(host);
                let name = name.split('/').next().unwrap_or(name).replace('*', "");
                let parts: Vec<&str> = name.split(':').collect();
                let name = if parts.len() == 2 { parts[0] } else { &name };
                if is_ipv4(name) {
                    if let Some(port) = parts.get(1).filter(|_| parts.len() == 2).and_then(|p| p.parse().ok()) {
                        (port_min, port_max) = (port, port);
                    }
                    routing.ip.push(Range { from: name.into(), to: name.into(), port_min, port_max, protocol });
                } else if !name.is_empty() {
                    domains.insert(name.to_string());
                }
            }
        }
        routing.domains = domains.into_iter().collect();
        routing.dns = elements(rclist, "Dns")
            .first()
            .and_then(|d| d.get("dnsserver"))
            .map(|s| s.split(';').filter(|s| !s.is_empty()).map(String::from).collect())
            .unwrap_or_default();
        routing
    }
}

/// The attributes of every `<tag ...>` in `text`.
fn elements(text: &str, tag: &str) -> Vec<HashMap<String, String>> {
    let open = format!("<{tag}");
    let mut found = vec![];
    let mut rest = text;
    while let Some(start) = rest.find(&open) {
        rest = &rest[start + open.len()..];
        if !rest.starts_with(char::is_whitespace) {
            continue;
        }
        let Some(end) = rest.find('>') else { break };
        found.push(attributes(&rest[..end]));
        rest = &rest[end..];
    }
    found
}

/// `key="value"` pairs.
fn attributes(mut text: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    while let Some(eq) = text.find("=\"") {
        let key_start = text[..eq]
            .char_indices()
            .rev()
            .find(|&(_, c)| !(c.is_alphanumeric() || c == '_'))
            .map_or(0, |(i, c)| i + c.len_utf8());
        let value = &text[eq + 2..];
        let Some(close) = value.find('"') else { break };
        if key_start < eq {
            map.insert(text[key_start..eq].to_string(), value[..close].replace("&amp;", "&"));
        }
        text = &value[close + 1..];
    }
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totp_matches_the_rfc_6238_vectors() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // "12345678901234567890"
        assert_eq!(totp(secret, 59).unwrap(), "287082");
        assert_eq!(totp(secret, 1_111_111_109).unwrap(), "081804");
        assert_eq!(totp(secret, 1_234_567_890).unwrap(), "005924");
    }

    #[test]
    fn the_resource_list_becomes_ranges_domains_and_resolvers() {
        let routing = Routing::parse(r#"
            <Resource><Rcs>
            <Rc id="1" type="1" proto="0" host="10.0.0.0~10.255.255.255;https://git.example.edu.cn/x;10.1.2.3:2222" port="1~65535;0~0;0~0" />
            <Rc id="2" type="0" proto="0" host="192.168.0.1" port="80~80" />
            </Rcs><Dns dnsserver="10.10.0.21;10.10.0.22;" data="" /></Resource>"#);
        let range = |from: &str, to: &str, port_min, port_max| Range { from: from.into(), to: to.into(), port_min, port_max, protocol: "tcp" };
        assert_eq!(routing.ip, [range("10.0.0.0", "10.255.255.255", 1, 65535), range("10.1.2.3", "10.1.2.3", 2222, 2222)]);
        assert_eq!(routing.domains, ["git.example.edu.cn"]);
        assert_eq!(routing.dns, ["10.10.0.21", "10.10.0.22"]);
    }

    #[test]
    fn http_bodies_are_read_to_their_length_through_chunks_or_to_the_end() {
        let chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n<Aut\r\n2\r\nh>\r\n0\r\n\r\n";
        assert_eq!(parse_http(chunked, false).unwrap().body, "<Auth>");
        assert!(parse_http(&chunked[..chunked.len() - 7], false).is_none());
        let sized = b"HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\nno";
        assert_eq!(parse_http(sized, false).unwrap().status, 404);
        let open = b"HTTP/1.0 200 OK\r\n\r\nrest";
        assert!(parse_http(open, false).is_none());
        assert_eq!(parse_http(open, true).unwrap().body, "rest");
    }

    #[test]
    fn a_chunk_size_that_overflows_is_refused_rather_than_panicking() {
        let huge = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\nx\r\n0\r\n\r\n";
        assert!(parse_http(huge, false).is_none());
        assert!(parse_http(huge, true).is_none());
    }

    #[test]
    fn gateway_addresses_lose_scheme_and_path() {
        let g = Gateway::new("https://vpn.example.edu.cn:4443/portal", Underlay::default());
        assert_eq!((g.host.as_str(), g.port), ("vpn.example.edu.cn", 4443));
        assert_eq!(Gateway::new("vpn.example.edu.cn", Underlay::default()).port, 443);
    }
}
