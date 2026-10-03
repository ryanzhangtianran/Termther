//! Termther's EasyConnect client.
//!
//! The whole protocol runs in-process: the login (gateway.rs), the packet
//! tunnel (tls.rs, session.rs) and a small TCP/IP stack on top of it
//! (stack.rs). There is no TUN device, no root and no routing change.
//!
//! Two front ends share it: the `termther-ec` SOCKS5 proxy (main.rs) and the
//! macOS app, through the C ABI in ffi.rs.

use std::any::Any;
use std::fmt;
use std::io;

#[macro_export]
macro_rules! bail {
    ($($t:tt)*) => { return Err($crate::Error::Msg(format!($($t)*))) };
}

mod ffi;
pub mod gateway;
pub mod session;
pub mod stack;
mod tls;

#[derive(Debug)]
pub enum Error {
    /// The other end closed the connection.
    Closed,
    Msg(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Error::Closed => f.write_str("connection closed"),
            Error::Msg(m) => f.write_str(m),
        }
    }
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Error {
        if e.kind() == io::ErrorKind::UnexpectedEof { Error::Closed } else { Error::Msg(e.to_string()) }
    }
}

impl From<String> for Error {
    fn from(m: String) -> Error {
        Error::Msg(m)
    }
}

impl From<&str> for Error {
    fn from(m: &str) -> Error {
        Error::Msg(m.into())
    }
}

pub type Result<T> = std::result::Result<T, Error>;


/// A caught panic, as the reason the tunnel stopped.
fn panic_message(panic: Box<dyn Any + Send>) -> String {
    let what = panic.downcast_ref::<&str>().copied().or_else(|| panic.downcast_ref::<String>().map(String::as_str));
    format!("internal error in the EasyConnect engine: {}", what.unwrap_or("a panic"))
}
