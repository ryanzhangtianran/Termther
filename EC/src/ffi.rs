//! The C ABI the macOS app links against; declared in include/termther_ec.h.
//!
//! Every entry point catches panics, because a library that can kill the app
//! is not a library. Returned strings belong to the caller, who frees them with
//! `ec_string_free`.

use crate::gateway::{self, Probe, Routing, Underlay};
use crate::session::{Credentials, Session};
use socket2::{Domain, Socket, Type};
use std::ffi::{c_char, CStr, CString};
use std::os::fd::IntoRawFd;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::null_mut;
use std::sync::Arc;
use std::thread;

pub struct EcSession(Arc<Session>);

fn text(p: *const c_char) -> Option<String> {
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()).filter(|s| !s.is_empty())
}

fn owned(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap_or_default().into_raw()
}

fn underlay(interface: *const c_char, dns: *const c_char) -> Underlay {
    Underlay { interface: text(interface), dns: text(dns) }
}

fn session<'a>(p: *const EcSession) -> &'a Session {
    &unsafe { &*p }.0
}

/// Runs `f`, turning an error or a panic into a message in `*error` and `failed` as the result.
fn guard<T>(error: *mut *mut c_char, failed: T, f: impl FnOnce() -> crate::Result<T>) -> T {
    let message = match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => return value,
        Ok(Err(e)) => e.to_string(),
        Err(_) => "internal error in the EasyConnect engine".to_string(),
    };
    if !error.is_null() {
        unsafe { *error = owned(message) };
    }
    failed
}

fn quiet<T>(failed: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(failed)
}

#[no_mangle]
pub extern "C" fn ec_login(
    gateway: *const c_char, username: *const c_char, password: *const c_char, totp_secret: *const c_char,
    interface: *const c_char, dns: *const c_char, error: *mut *mut c_char,
) -> *mut EcSession {
    guard(error, null_mut(), || {
        let credentials = Credentials {
            username: text(username).unwrap_or_default(),
            password: text(password).unwrap_or_default(),
            totp_secret: text(totp_secret),
        };
        let session = Session::open(&text(gateway).unwrap_or_default(), &credentials, underlay(interface, dns))?;
        Ok(Box::into_raw(Box::new(EcSession(session))))
    })
}

/// Stops the tunnel. The handle stays valid until `ec_free`, so a call still
/// running on another thread finishes safely, with an error.
#[no_mangle]
pub extern "C" fn ec_close(session: *const EcSession) {
    quiet((), || self::session(session).close())
}

/// Stops the tunnel if it is still up and releases the handle.
#[no_mangle]
pub unsafe extern "C" fn ec_free(session: *mut EcSession) {
    if !session.is_null() {
        quiet((), || Box::from_raw(session).0.close())
    }
}

#[no_mangle]
pub extern "C" fn ec_address(session: *const EcSession) -> *mut c_char {
    quiet(null_mut(), || owned(self::session(session).address.to_string()))
}

/// The routes, domains and resolvers the gateway granted, as JSON.
#[no_mangle]
pub extern "C" fn ec_routing_json(session: *const EcSession) -> *mut c_char {
    quiet(null_mut(), || owned(json(&self::session(session).routing)))
}

/// Why the tunnel stopped carrying traffic, or NULL while it still does.
#[no_mangle]
pub extern "C" fn ec_failure(session: *const EcSession) -> *mut c_char {
    quiet(null_mut(), || self::session(session).failure().map_or(null_mut(), owned))
}

#[no_mangle]
pub extern "C" fn ec_set_underlay(session: *const EcSession, interface: *const c_char, dns: *const c_char) {
    quiet((), || self::session(session).set_underlay(underlay(interface, dns)))
}

/// Resolves through the tunnel with the gateway's DNS servers. Blocks.
#[no_mangle]
pub extern "C" fn ec_resolve(session: *const EcSession, host: *const c_char, error: *mut *mut c_char) -> *mut c_char {
    guard(error, null_mut(), || {
        Ok(owned(self::session(session).resolve(&text(host).unwrap_or_default())?.to_string()))
    })
}

/// Opens a TCP connection inside the tunnel and returns a real descriptor:
/// one end of a socketpair, with the stack pumping the other. Blocks.
#[no_mangle]
pub extern "C" fn ec_dial(session: *const EcSession, host: *const c_char, port: u16, error: *mut *mut c_char) -> i32 {
    guard(error, -1, || {
        let session = self::session(session);
        let (ours, theirs) = Socket::pair(Domain::UNIX, Type::STREAM, None)?;
        #[cfg(target_vendor = "apple")]
        for socket in [&ours, &theirs] {
            socket.set_nosigpipe(true)?;
        }
        let _ = ours.set_send_buffer_size(1 << 20);
        let _ = ours.set_recv_buffer_size(1 << 20);
        let link = session.dial(&text(host).unwrap_or_default(), port, &ours)?;
        let stack = session.stack.clone();
        thread::spawn(move || stack.pump(link, ours));
        Ok(theirs.into_raw_fd())
    })
}

/// 0 for an EasyConnect gateway, 1 for something else, 2 for unreachable;
/// `*detail` says what was seen. Blocks.
#[no_mangle]
pub extern "C" fn ec_probe(gateway: *const c_char, interface: *const c_char, dns: *const c_char, detail: *mut *mut c_char) -> i32 {
    let (kind, message) = quiet((2, "internal error in the EasyConnect engine".to_string()), || {
        match gateway::probe(&text(gateway).unwrap_or_default(), underlay(interface, dns)) {
            Probe::EasyConnect(d) => (0, d),
            Probe::SomethingElse(d) => (1, d),
            Probe::Unreachable(d) => (2, d),
        }
    });
    if !detail.is_null() {
        unsafe { *detail = owned(message) };
    }
    kind
}

#[no_mangle]
pub unsafe extern "C" fn ec_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Shaped for Swift's `EasyConnect.Routing`, which is Codable.
fn json(routing: &Routing) -> String {
    fn quote(s: &str) -> String {
        let mut out = String::from("\"");
        for c in s.chars() {
            match c {
                '"' => out += "\\\"",
                '\\' => out += "\\\\",
                c if c < ' ' => out += &format!("\\u{:04x}", c as u32),
                c => out.push(c),
            }
        }
        out + "\""
    }
    let list = |v: &[String]| v.iter().map(|s| quote(s)).collect::<Vec<_>>().join(",");
    let ranges = routing.ip.iter().map(|r| {
        format!(r#"{{"from":{},"to":{},"portMin":{},"portMax":{},"protocol":{}}}"#,
            quote(&r.from), quote(&r.to), r.port_min, r.port_max, quote(r.protocol))
    });
    format!(r#"{{"ip":[{}],"domains":[{}],"dns":[{}]}}"#, ranges.collect::<Vec<_>>().join(","), list(&routing.domains), list(&routing.dns))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gateway::Range;

    #[test]
    fn routing_json_has_the_shape_swift_decodes() {
        let routing = Routing {
            ip: vec![Range { from: "10.0.0.0".into(), to: "10.0.0.9".into(), port_min: 22, port_max: 22, protocol: "tcp" }],
            domains: vec!["a\"b".into()],
            dns: vec!["10.10.0.21".into()],
        };
        assert_eq!(json(&routing), r#"{"ip":[{"from":"10.0.0.0","to":"10.0.0.9","portMin":22,"portMax":22,"protocol":"tcp"}],"domains":["a\"b"],"dns":["10.10.0.21"]}"#);
    }

    #[test]
    fn errors_come_back_as_messages() {
        let mut error = null_mut();
        let gateway = CString::new("127.0.0.1:1").unwrap();
        assert!(ec_login(gateway.as_ptr(), null_mut(), null_mut(), null_mut(), null_mut(), null_mut(), &mut error).is_null());
        let message = unsafe { CStr::from_ptr(error) }.to_string_lossy().into_owned();
        assert!(message.contains("127.0.0.1:1"), "{message}");
        unsafe { ec_string_free(error) };

        let mut detail = null_mut();
        assert_eq!(ec_probe(gateway.as_ptr(), null_mut(), null_mut(), &mut detail), 2);
        unsafe { ec_string_free(detail) };
    }
}
