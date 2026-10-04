//! A logged-in session: the packet tunnel, and the TCP/IP stack on top of it.
//!
//! Three threads carry it. One reads the receiving stream into the stack, one
//! writes the stack's packets to the sending stream, and one keeps the session
//! alive. A broken stream is reopened, with up to five attempts in a row in
//! each direction; after that the reason is recorded in `failure()` and the
//! threads end. A panic on any of them is recorded there too. Nothing here
//! ends the process.

use crate::gateway::{Gateway, Routing, Underlay};
use crate::stack::{dns, Link, Stack};
use crate::tls::Tls;
use crate::{Error, Result};
use socket2::Socket;
use std::net::{Ipv4Addr, Shutdown, TcpStream};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

pub struct Credentials {
    pub username: String,
    pub password: String,
    /// Base32 TOTP secret, when the account carries a second factor.
    pub totp_secret: Option<String>,
}

pub struct Session {
    /// The tunnel address the gateway handed this client.
    pub address: Ipv4Addr,
    pub routing: Routing,
    pub stack: Arc<Stack>,
    /// Locked only to copy or update; every network call works on a copy.
    gateway: Mutex<Gateway>,
    /// The connection that asked for the address. The gateway tears the tunnel down if it closes.
    _control: Tls,
    state: Mutex<State>,
    /// A handle on the sending thread's queue; an empty packet wakes it to notice a close.
    packets: mpsc::Sender<Vec<u8>>,
}

struct State {
    failure: Option<String>,
    closed: bool,
    /// The receiving, sending and control streams' sockets, to wake the threads blocked on them.
    sockets: [Option<TcpStream>; 3],
    /// Attempts to reopen in a row, per direction, and when the last one started.
    reopened: [(u32, Instant); 2],
}

impl Session {
    pub fn open(gateway: &str, credentials: &Credentials, underlay: Underlay) -> Result<Arc<Session>> {
        let mut gateway = Gateway::new(gateway, underlay);
        gateway.login(&credentials.username, &credentials.password, credentials.totp_secret.as_deref())?;
        gateway.request_token()?;
        let started = Instant::now();
        let routing = gateway.resources().unwrap_or_default();
        // The gateway refuses an address requested within a second of the token.
        if let Some(wait) = Duration::from_secs(1).checked_sub(started.elapsed()) {
            thread::sleep(wait);
        }
        let control = gateway.request_address()?;
        let sender = gateway.open_tunnel(true)?;
        let receiver = gateway.open_tunnel(false)?;
        receiver.socket().set_read_timeout(None)?; // an idle tunnel is silent

        let (packets, queue) = mpsc::channel();
        let output = packets.clone();
        let clone = |t: &Tls| t.socket().try_clone().map(Some);
        let sockets = [clone(&receiver)?, clone(&sender)?, clone(&control)?];
        let session = Arc::new(Session {
            address: gateway.address.into(),
            routing,
            stack: Stack::new(gateway.address, move |packet| drop(output.send(packet))),
            gateway: Mutex::new(gateway),
            _control: control,
            state: Mutex::new(State { failure: None, closed: false, sockets, reopened: [(0, Instant::now()); 2] }),
            packets,
        });

        let s = session.clone();
        thread::spawn(move || s.guard(|| s.receive(receiver)));
        let s = session.clone();
        thread::spawn(move || s.guard(|| s.send(sender, queue)));
        let weak = Arc::downgrade(&session);
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(60));
            let Some(s) = weak.upgrade() else { return };
            let mut alive = false;
            let closed = s.state().closed;
            s.guard(|| alive = !closed && s.gateway().update_session());
            if !alive {
                return;
            }
        });
        Ok(session)
    }

    fn gateway(&self) -> Gateway {
        self.gateway.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Tolerates a poisoned lock, so a caught panic can still be recorded and read.
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Runs a thread's body, recording a panic as the failure rather than losing it with the thread.
    fn guard(&self, f: impl FnOnce()) {
        if let Err(panic) = catch_unwind(AssertUnwindSafe(f)) {
            self.fail(crate::panic_message(panic).into());
        }
    }

    /// Hands over a new interface and resolver. A broken stream is reopened
    /// with whatever was last given, and values from one network are wrong on
    /// the next.
    pub fn set_underlay(&self, underlay: Underlay) {
        self.gateway.lock().unwrap_or_else(|e| e.into_inner()).underlay = underlay;
    }

    /// Why the tunnel stopped carrying traffic, or None while it still does.
    pub fn failure(&self) -> Option<String> {
        self.state().failure.clone().or_else(|| self.stack.failure())
    }

    pub fn close(&self) {
        let sockets = {
            let mut state = self.state();
            state.closed = true;
            std::mem::take(&mut state.sockets)
        };
        self.stack.stop();
        for socket in sockets.into_iter().flatten() {
            let _ = socket.shutdown(Shutdown::Both);
        }
        let _ = self.packets.send(vec![]);
    }

    /// Resolves with the DNS servers the gateway advertised, through the
    /// tunnel. This is the only way to reach split-horizon names.
    pub fn resolve(&self, host: &str) -> Result<Ipv4Addr> {
        if let Ok(ip) = host.parse() {
            return Ok(ip);
        }
        let servers: Vec<Ipv4Addr> = self.routing.dns.iter().filter_map(|s| s.parse().ok()).filter(|s: &Ipv4Addr| !s.is_unspecified()).collect();
        if servers.is_empty() {
            bail!("the gateway advertised no DNS server");
        }
        let id = rand::random();
        for server in servers {
            for _ in 0..2 {
                let reply = self.stack.exchange(&dns::query(host, id), server, 53, Duration::from_secs(3));
                if let Some(found) = reply.and_then(|r| dns::first_address(&r, id)) {
                    return Ok(found);
                }
            }
        }
        bail!("{host}: no answer from {}", self.routing.dns.join(", "))
    }

    /// Opens a TCP connection inside the tunnel on behalf of `app`.
    pub fn dial(&self, host: &str, port: u16, app: &Socket) -> Result<Link> {
        let address = self.resolve(host)?;
        self.stack.connect(address, port, app).map_err(|e| format!("{host}:{port}: {e}").into())
    }

    /// Reads packets from the gateway until the session closes.
    fn receive(&self, mut stream: Tls) {
        loop {
            let record = match stream.read() {
                Ok(record) => record,
                Err(e) => match self.reopen(false, e) {
                    Some(fresh) => {
                        stream = fresh;
                        continue;
                    }
                    None => return,
                },
            };
            // Normally a record holds one packet, but split it in case it holds several.
            let mut offset = 0;
            while offset + 20 <= record.len() {
                let length = u16::from_be_bytes([record[offset + 2], record[offset + 3]]) as usize;
                if length < 20 || offset + length > record.len() {
                    break;
                }
                self.stack.receive(&record[offset..offset + length]);
                offset += length;
            }
        }
    }

    /// Sends what has queued up since the last write in one write, still one
    /// record per packet; an empty packet only wakes the thread.
    fn send(&self, mut stream: Tls, queue: mpsc::Receiver<Vec<u8>>) {
        let mut batch = vec![];
        while let Ok(first) = queue.recv() {
            if self.state().closed {
                return;
            }
            batch.clear();
            batch.push(first);
            let mut bytes = batch[0].len();
            while batch.len() < 64 && bytes < 65536 {
                let Ok(packet) = queue.try_recv() else { break };
                bytes += packet.len();
                batch.push(packet);
            }
            if let Err(e) = stream.write_each(batch.iter().map(Vec::as_slice)) {
                let Some(fresh) = self.reopen(true, e) else { return };
                stream = fresh;
                let _ = stream.write_each(batch.iter().map(Vec::as_slice));
            }
        }
    }

    /// Replaces a broken stream, making up to five attempts in a row in each
    /// direction. A failed attempt waits before the next, half a second and then
    /// twice as long each time, so a network change has a few seconds to settle.
    /// A stream that then lasts a minute starts the count again, so a long
    /// session survives any number of network changes.
    fn reopen(&self, sending: bool, mut error: Error) -> Option<Tls> {
        let mut pause = Duration::from_millis(500);
        loop {
            let count = {
                let mut state = self.state();
                if state.closed {
                    return None;
                }
                let (count, last) = &mut state.reopened[sending as usize];
                if last.elapsed() > Duration::from_secs(60) {
                    *count = 0;
                }
                *count += 1;
                *last = Instant::now();
                *count
            };
            if count > 5 {
                return self.fail(error);
            }
            match self.gateway().open_tunnel(sending) {
                Ok(fresh) => return self.install(sending, fresh),
                Err(e) => error = e,
            }
            if count < 5 {
                thread::sleep(pause);
                pause *= 2;
            }
        }
    }

    /// Puts a fresh stream in place of the broken one, whose socket is shut down.
    fn install(&self, sending: bool, fresh: Tls) -> Option<Tls> {
        if !sending {
            let _ = fresh.socket().set_read_timeout(None);
        }
        let mut state = self.state();
        if state.closed {
            let _ = fresh.socket().shutdown(Shutdown::Both);
            return None;
        }
        let broken = std::mem::replace(&mut state.sockets[sending as usize], fresh.socket().try_clone().ok());
        if let Some(broken) = broken {
            let _ = broken.shutdown(Shutdown::Both);
        }
        Some(fresh)
    }

    fn fail(&self, error: Error) -> Option<Tls> {
        let mut state = self.state();
        if !state.closed && state.failure.is_none() {
            state.failure = Some(error.to_string());
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn credentials(username: String, password: String) -> Credentials {
        Credentials { username, password, totp_secret: std::env::var("TERMTHER_EC_TOTP").ok() }
    }

    #[test]
    fn a_login_to_nothing_fails_rather_than_hanging() {
        let result = Session::open("127.0.0.1:1", &credentials("x".into(), "y".into()), Underlay::default());
        assert!(result.is_err());
    }

    /// Live login, run by hand. The password is read from the environment and never printed:
    ///   read -s TERMTHER_EC_PASSWORD; export TERMTHER_EC_PASSWORD
    ///   TERMTHER_EC_GATEWAY=host:443 TERMTHER_EC_USER=you cargo test live_login -- --nocapture
    #[test]
    fn live_login() {
        let (Ok(gateway), Ok(user), Ok(password)) =
            (std::env::var("TERMTHER_EC_GATEWAY"), std::env::var("TERMTHER_EC_USER"), std::env::var("TERMTHER_EC_PASSWORD"))
        else {
            return;
        };
        let session = Session::open(&gateway, &credentials(user, password), Underlay::default()).unwrap();
        // The address is the proof: it comes from the gateway and exists only inside a real tunnel.
        println!("assigned {}, {} ranges, {} DNS", session.address, session.routing.ip.len(), session.routing.dns.len());
        assert!(!session.address.is_unspecified());
        session.close();
    }
}
