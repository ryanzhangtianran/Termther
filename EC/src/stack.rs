//! A userspace TCP/IP stack that handles only outbound TCP connections and DNS
//! queries, sent as IPv4 packets through the tunnel.
//!
//! EasyConnect is a layer-3 tunnel and this client has no TUN device, so the
//! process itself must turn packets into streams. Each connection is pumped
//! against a socket: a SOCKS5 client, or one end of a socketpair whose other
//! end the app hands to libssh2.
//!
//! All state sits behind one mutex. Packets from the tunnel, the timer thread
//! and the two pump threads of each connection take turns at it; a condvar
//! wakes the pumps when something they wait on changes.
//! ponytail: one lock and notify_all for the whole stack; per-connection locks if many
//! busy connections ever contend.

use rand::Rng;
use std::collections::{HashMap, VecDeque};
use std::io::{ErrorKind, Read, Write};
use socket2::Socket;
use std::net::{Ipv4Addr, Shutdown};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{mpsc, Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

/// The tunnel's 1400-byte MTU, less the IP and TCP headers.
const MSS: usize = 1360;
/// A peer's MSS below this is ignored in favour of the default 536. Zero would stall the sender.
const MIN_MSS: usize = 64;
const RECEIVE_CAPACITY: usize = 1 << 20;
const SEND_LIMIT: usize = 1 << 19;
const WINDOW_SHIFT: u32 = 6;

const FIN: u8 = 0x01;
const SYN: u8 = 0x02;
const RST: u8 = 0x04;
const PSH: u8 = 0x08;
const ACK: u8 = 0x10;

pub struct Stack {
    inner: Mutex<Inner>,
    changed: Condvar,
}

/// Names one connection. The id tells a connection apart from a later one that reuses its port.
#[derive(Clone, Copy)]
pub struct Link {
    port: u16,
    id: u64,
}

struct Inner {
    conns: HashMap<u16, Conn>,
    datagrams: HashMap<u16, mpsc::Sender<Vec<u8>>>,
    wire: Wire,
    next_id: u64,
    /// A panic caught on one of the stack's threads.
    failure: Option<String>,
}

/// What every outgoing packet needs.
struct Wire {
    address: [u8; 4],
    packet_id: u16,
    stopped: bool,
    /// A connection has closed since closed ones were last forgotten.
    reaped: bool,
    output: Box<dyn Fn(Vec<u8>) + Send>,
}

impl Stack {
    /// `output` sends one IPv4 packet into the tunnel. It is called with the stack locked, so it must not block.
    pub fn new(address: [u8; 4], output: impl Fn(Vec<u8>) + Send + 'static) -> Arc<Stack> {
        let wire = Wire { address, packet_id: 0, stopped: false, reaped: false, output: Box::new(output) };
        let stack = Arc::new(Stack {
            inner: Mutex::new(Inner { conns: HashMap::new(), datagrams: HashMap::new(), wire, next_id: 0, failure: None }),
            changed: Condvar::new(),
        });
        let weak = Arc::downgrade(&stack);
        // ponytail: timers fire on a 100 ms tick; per-connection timers if that granularity ever matters.
        thread::spawn(move || loop {
            thread::sleep(Duration::from_millis(100));
            let Some(stack) = weak.upgrade() else { return };
            let mut running = false;
            stack.guard(|| running = stack.tick());
            if !running {
                return;
            }
        });
        stack
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Runs `f`, recording a panic as the stack's failure rather than losing it with the thread.
    fn guard(&self, f: impl FnOnce()) {
        if let Err(panic) = catch_unwind(AssertUnwindSafe(f)) {
            self.lock().failure.get_or_insert(crate::panic_message(panic));
        }
    }

    /// A panic on one of the stack's threads, which leaves the tunnel unable to carry traffic.
    pub fn failure(&self) -> Option<String> {
        self.lock().failure.clone()
    }

    fn wait<'a>(&self, guard: MutexGuard<'a, Inner>) -> MutexGuard<'a, Inner> {
        self.changed.wait(guard).unwrap_or_else(|e| e.into_inner())
    }

    /// Runs `f` on the state, then forgets closed connections and wakes anyone waiting.
    fn with<R>(&self, f: impl FnOnce(&mut Inner) -> R) -> R {
        let mut inner = self.lock();
        let result = f(&mut inner);
        if std::mem::take(&mut inner.wire.reaped) {
            inner.conns.retain(|_, c| c.state != State::Closed);
        }
        drop(inner);
        self.changed.notify_all();
        result
    }

    /// Hands the stack a packet from the tunnel.
    pub fn receive(&self, packet: &[u8]) {
        self.with(|inner| inner.input(packet))
    }

    pub fn stop(&self) {
        self.with(|inner| {
            inner.wire.stopped = true;
            for c in inner.conns.values_mut() {
                c.close(&mut inner.wire, "the tunnel closed", false);
            }
            inner.datagrams.clear();
        })
    }

    fn tick(&self) -> bool {
        self.with(|inner| {
            let now = Instant::now();
            for c in inner.conns.values_mut() {
                if c.deadline.is_some_and(|d| d <= now) {
                    c.deadline = None;
                    c.timeout(&mut inner.wire);
                }
            }
            !inner.wire.stopped
        })
    }

    // MARK: TCP

    /// Opens a connection and returns once it is established. `app` is only
    /// shut down if the connection later closes; until then it is the caller's.
    pub fn connect(&self, remote: Ipv4Addr, port: u16, app: &Socket) -> Result<Link, String> {
        let (connected, result) = mpsc::channel();
        let app = app.try_clone().map_err(|e| e.to_string())?;
        let link = self.with(|inner| {
            if inner.wire.stopped {
                return Err("the tunnel closed".to_string());
            }
            inner.next_id += 1;
            let link = Link { port: inner.free_port(), id: inner.next_id };
            let mut c = Conn::new(link, remote.octets(), port, app, connected);
            c.send_syn(&mut inner.wire);
            c.arm();
            inner.conns.insert(link.port, c);
            Ok(link)
        })?;
        result.recv().unwrap_or_else(|_| Err("the tunnel closed".into()))?;
        Ok(link)
    }

    /// Carries bytes between `app` and the connection until both sides are done.
    pub fn pump(self: &Arc<Self>, link: Link, app: Socket) {
        let Ok(writer) = app.try_clone() else { return self.abort(link) };
        let stack = self.clone();
        thread::spawn(move || stack.guard(|| stack.write_to_app(link, writer)));
        self.guard(|| self.read_from_app(link, app));
    }

    /// Resets a connection, for one the app will never pump.
    pub fn abort(&self, link: Link) {
        self.with(|inner| inner.on(link, |c, wire| c.close(wire, "closed", true)))
    }

    fn read_from_app(&self, link: Link, mut app: Socket) {
        let mut buffer = vec![0; 65536];
        loop {
            // Waits while the send buffer is full, which stops the app from outrunning the peer.
            let mut inner = self.lock();
            loop {
                match inner.conn(link) {
                    None => return,
                    Some(c) if c.send_buffer.len() >= SEND_LIMIT => {}
                    Some(_) => break,
                }
                inner = self.wait(inner);
            }
            drop(inner);

            let n = match app.read(&mut buffer) {
                Ok(n) => n,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return self.abort(link),
            };
            self.with(|inner| {
                inner.on(link, |c, wire| {
                    if n == 0 { c.app_closed = true } else { c.send_buffer.extend(&buffer[..n]) }
                    c.flush(wire);
                    c.finish_if_done(wire);
                })
            });
            if n == 0 {
                return;
            }
        }
    }

    fn write_to_app(&self, link: Link, mut app: Socket) {
        // One buffer for the connection's life, filled by copying slices: the
        // stack is locked while it fills.
        let mut chunk = Vec::with_capacity(65536);
        loop {
            let mut inner = self.lock();
            loop {
                let Some(c) = inner.conn(link) else { return };
                if !c.to_app.is_empty() {
                    chunk.clear();
                    let [front, back] = range(&c.to_app, 0, c.to_app.len().min(65536));
                    chunk.extend_from_slice(front);
                    chunk.extend_from_slice(back);
                    break;
                }
                if c.peer_closed {
                    let _ = app.shutdown(Shutdown::Write);
                    return;
                }
                inner = self.wait(inner);
            }
            drop(inner);

            if app.write_all(&chunk).is_err() {
                // The app hung up.
                return self.abort(link);
            }
            self.with(|inner| {
                inner.on(link, |c, wire| {
                    let before = c.to_app.len();
                    c.to_app.drain(..chunk.len());
                    // The window was more than half shut and has reopened. Say so, or the peer waits.
                    if before > RECEIVE_CAPACITY / 2 && c.to_app.len() <= RECEIVE_CAPACITY / 2 {
                        c.send(wire, ACK, c.snd_nxt, &[], &[]);
                    }
                    c.finish_if_done(wire);
                })
            });
        }
    }

    // MARK: UDP

    /// Sends one datagram and waits for one reply, or None after `timeout`.
    pub fn exchange(&self, payload: &[u8], remote: Ipv4Addr, port: u16, timeout: Duration) -> Option<Vec<u8>> {
        let (sender, reply) = mpsc::channel();
        let local = self.with(|inner| {
            if inner.wire.stopped {
                return None;
            }
            let local = inner.free_port();
            inner.datagrams.insert(local, sender);
            let mut packet = Vec::with_capacity(28 + payload.len());
            packet.extend([0; 20]); // the IP header, filled in by emit
            for field in [local, port, (8 + payload.len()) as u16, 0] {
                packet.extend(field.to_be_bytes());
            }
            packet.extend(payload);
            let sum = checksum_of(&[&pseudo_header(inner.wire.address, remote.octets(), 17, packet.len() - 20), &packet[20..]]);
            packet[26..28].copy_from_slice(&(if sum == 0 { 0xFFFF } else { sum }).to_be_bytes());
            inner.wire.emit(remote.octets(), 17, packet);
            Some(local)
        })?;
        let reply = reply.recv_timeout(timeout).ok();
        self.with(|inner| inner.datagrams.remove(&local));
        reply
    }
}

impl Inner {
    fn conn(&self, link: Link) -> Option<&Conn> {
        self.conns.get(&link.port).filter(|c| c.id == link.id)
    }

    fn on(&mut self, link: Link, f: impl FnOnce(&mut Conn, &mut Wire)) {
        if let Some(c) = self.conns.get_mut(&link.port).filter(|c| c.id == link.id) {
            f(c, &mut self.wire);
        }
    }

    fn free_port(&self) -> u16 {
        loop {
            let port = rand::thread_rng().gen_range(49152..=65535);
            if !self.conns.contains_key(&port) && !self.datagrams.contains_key(&port) {
                return port;
            }
        }
    }

    fn input(&mut self, packet: &[u8]) {
        if self.wire.stopped || packet.len() < 20 || packet[0] >> 4 != 4 {
            return;
        }
        let header_length = (packet[0] & 0x0F) as usize * 4;
        let total = u16::from_be_bytes([packet[2], packet[3]]) as usize;
        // Drops fragments. The gateway reassembles before forwarding, and TCP segments here fit the MTU.
        if header_length < 20 || total < header_length || total > packet.len()
            || packet[6] & 0x3F != 0 || packet[7] != 0 || packet[16..20] != self.wire.address
        {
            return;
        }
        let source: [u8; 4] = packet[12..16].try_into().unwrap();
        let payload = &packet[header_length..total];
        match packet[9] {
            6 => self.tcp_input(source, payload),
            17 if payload.len() >= 8 => {
                if let Some(waiting) = self.datagrams.remove(&u16::from_be_bytes([payload[2], payload[3]])) {
                    let _ = waiting.send(payload[8..].to_vec());
                }
            }
            _ => {}
        }
    }

    fn tcp_input(&mut self, source: [u8; 4], segment: &[u8]) {
        if segment.len() < 20 {
            return;
        }
        let data_offset = (segment[12] >> 4) as usize * 4;
        let Some(c) = self.conns.get_mut(&u16::from_be_bytes([segment[2], segment[3]])) else { return };
        if data_offset < 20 || data_offset > segment.len() || c.remote != source
            || c.remote_port != u16::from_be_bytes([segment[0], segment[1]])
        {
            return;
        }
        let wire = &mut self.wire;
        let seq = u32::from_be_bytes(segment[4..8].try_into().unwrap());
        let ack = u32::from_be_bytes(segment[8..12].try_into().unwrap());
        let flags = segment[13];
        let window = u16::from_be_bytes([segment[14], segment[15]]) as usize;
        let payload = &segment[data_offset..];

        if flags & RST != 0 {
            let reason = if c.state == State::Connecting { "connection refused" } else { "connection reset" };
            return c.close(wire, reason, false);
        }

        if c.state == State::Connecting {
            if flags & (SYN | ACK) != SYN | ACK || ack != c.snd_una.wrapping_add(1) {
                return;
            }
            let mut options = &segment[20..data_offset];
            while let Some(&kind) = options.first() {
                if kind == 0 {
                    break;
                }
                if kind == 1 {
                    options = &options[1..];
                    continue;
                }
                if options.len() < 2 || options.len() < options[1] as usize {
                    break;
                }
                let length = (options[1] as usize).max(2);
                if kind == 2 && length == 4 {
                    let mss = u16::from_be_bytes([options[2], options[3]]) as usize;
                    if mss >= MIN_MSS {
                        c.peer_mss = mss;
                    }
                }
                if kind == 3 && length == 3 {
                    c.peer_shift = options[2].min(14) as u32;
                    c.scaled = true;
                }
                options = &options[length..];
            }
            c.state = State::Open;
            (c.snd_una, c.snd_nxt, c.snd_max) = (ack, ack, ack);
            c.rcv_nxt = seq.wrapping_add(1);
            c.peer_window = window;
            c.retries = 0;
            c.rto = 1.0;
            c.deadline = None;
            c.send(wire, ACK, c.snd_nxt, &[], &[]);
            if let Some(connected) = c.connected.take() {
                let _ = connected.send(Ok(()));
            }
            return;
        }

        if flags & ACK != 0 {
            c.process_ack(wire, ack, window, payload.is_empty() && flags & FIN == 0);
        }

        if (!payload.is_empty() || flags & FIN != 0) && c.state == State::Open {
            // Data past a gap is held until the gap fills, so one lost segment costs
            // one retransmission rather than the rest of the window. The duplicate
            // ACK below tells the peer where the gap is.
            let skip = c.rcv_nxt.wrapping_sub(seq) as i32;
            if skip >= 0 && skip as usize <= payload.len() {
                let fresh = &payload[skip as usize..];
                if c.deliver(fresh) == fresh.len() && flags & FIN != 0 {
                    if !c.peer_closed {
                        c.peer_closed = true;
                        c.rcv_nxt = c.rcv_nxt.wrapping_add(1);
                    }
                } else {
                    c.deliver_held();
                }
            } else if skip < 0 && !payload.is_empty() {
                // A FIN on a held segment is dropped; the peer resends it once the data is acknowledged.
                c.hold(seq, payload);
            }
            if c.state == State::Open {
                c.send(wire, ACK, c.snd_nxt, &[], &[]);
            }
        }
        c.flush(wire);
        c.finish_if_done(wire);
    }
}

impl Wire {
    /// Sends `packet`, whose first 20 bytes are left for the IP header.
    fn emit(&mut self, remote: [u8; 4], protocol: u8, mut packet: Vec<u8>) {
        if self.stopped {
            return;
        }
        self.packet_id = self.packet_id.wrapping_add(1);
        let total = packet.len() as u16;
        let header = &mut packet[..20];
        header[..2].copy_from_slice(&[0x45, 0]);
        header[2..4].copy_from_slice(&total.to_be_bytes());
        header[4..6].copy_from_slice(&self.packet_id.to_be_bytes());
        header[6..12].copy_from_slice(&[0x40, 0, 64, protocol, 0, 0]);
        header[12..16].copy_from_slice(&self.address);
        header[16..20].copy_from_slice(&remote);
        let sum = checksum(header);
        header[10..12].copy_from_slice(&sum.to_be_bytes());
        (self.output)(packet);
    }
}

#[derive(PartialEq)]
enum State {
    Connecting,
    Open,
    Closed,
}

/// One TCP connection's state.
struct Conn {
    id: u64,
    local_port: u16,
    remote: [u8; 4],
    remote_port: u16,
    /// The app's socket, kept to shut it down when the connection ends.
    app: Socket,
    connected: Option<mpsc::Sender<Result<(), String>>>,
    state: State,

    /// Bytes from `snd_una` on: sent and unacknowledged, then unsent.
    send_buffer: VecDeque<u8>,
    snd_una: u32,
    snd_nxt: u32,
    snd_max: u32,
    peer_window: usize,
    peer_shift: u32,
    peer_mss: usize,
    scaled: bool,
    app_closed: bool,
    fin_acked: bool,
    dup_acks: u32,

    rcv_nxt: u32,
    to_app: VecDeque<u8>,
    /// Segments that arrived past a gap, by sequence number.
    /// ponytail: a linear scan, as a window holds a few hundred segments at most.
    held: Vec<(u32, Vec<u8>)>,
    peer_closed: bool,

    deadline: Option<Instant>,
    rto: f64,
    retries: u32,
}

impl Conn {
    fn new(link: Link, remote: [u8; 4], remote_port: u16, app: Socket, connected: mpsc::Sender<Result<(), String>>) -> Conn {
        let iss: u32 = rand::random();
        Conn {
            id: link.id, local_port: link.port, remote, remote_port, app, connected: Some(connected),
            state: State::Connecting,
            send_buffer: VecDeque::new(), snd_una: iss, snd_nxt: iss.wrapping_add(1), snd_max: iss.wrapping_add(1),
            peer_window: 0, peer_shift: 0, peer_mss: 536, scaled: false,
            app_closed: false, fin_acked: false, dup_acks: 0,
            rcv_nxt: 0, to_app: VecDeque::new(), held: vec![], peer_closed: false,
            deadline: None, rto: 1.0, retries: 0,
        }
    }

    fn send_syn(&self, wire: &mut Wire) {
        // MSS, then a NOP and our window scale.
        let mss = (MSS as u16).to_be_bytes();
        self.send(wire, SYN, self.snd_una, &[], &[2, 4, mss[0], mss[1], 1, 3, 3, WINDOW_SHIFT as u8]);
    }

    /// Passes in-order data to the app, as much as the receive buffer has room for.
    fn deliver(&mut self, data: &[u8]) -> usize {
        let accepted = data.len().min(RECEIVE_CAPACITY - self.to_app.len());
        self.to_app.extend(&data[..accepted]);
        self.rcv_nxt = self.rcv_nxt.wrapping_add(accepted as u32);
        accepted
    }

    /// Delivers held segments that now continue the stream, and forgets those it already has.
    fn deliver_held(&mut self) {
        while let Some(i) = self.held.iter().position(|(seq, _)| self.rcv_nxt.wrapping_sub(*seq) as i32 >= 0) {
            let (seq, data) = self.held.swap_remove(i);
            let skip = self.rcv_nxt.wrapping_sub(seq) as usize;
            if skip < data.len() {
                self.deliver(&data[skip..]);
            }
        }
    }

    /// Keeps a segment that starts past a gap, if it fits in the window advertised.
    fn hold(&mut self, seq: u32, data: &[u8]) {
        let room = RECEIVE_CAPACITY - self.to_app.len();
        let ahead = seq.wrapping_sub(self.rcv_nxt) as usize;
        let held: usize = self.held.iter().map(|(_, d)| d.len()).sum();
        if ahead + data.len() <= room && held + data.len() <= room && !self.held.iter().any(|(s, _)| *s == seq) {
            self.held.push((seq, data.to_vec()));
        }
    }

    fn process_ack(&mut self, wire: &mut Wire, ack: u32, window: usize, pure: bool) {
        let acked = ack.wrapping_sub(self.snd_una) as i32;
        if acked < 0 || ack.wrapping_sub(self.snd_max) as i32 > 0 {
            return;
        }
        self.retries = 0;
        let peer_window = window << self.peer_shift;

        if acked == 0 {
            // Three duplicate ACKs: the first unacknowledged segment was probably lost.
            if pure && self.snd_nxt != self.snd_una && peer_window == self.peer_window {
                self.dup_acks += 1;
                if self.dup_acks == 3 {
                    self.retransmit_first(wire);
                }
            }
            self.peer_window = peer_window;
            return;
        }
        let data = (acked as usize).min(self.send_buffer.len());
        self.send_buffer.drain(..data);
        if acked as usize > data {
            self.fin_acked = true;
        }
        self.snd_una = ack;
        if (self.snd_nxt.wrapping_sub(ack) as i32) < 0 {
            self.snd_nxt = ack;
        }
        self.dup_acks = 0;
        self.rto = 1.0;
        if self.snd_una == self.snd_nxt { self.deadline = None } else { self.arm() }
        self.peer_window = peer_window;
    }

    /// Sends whatever the peer's window allows, and a FIN once the app has closed.
    fn flush(&mut self, wire: &mut Wire) {
        if self.state != State::Open {
            return;
        }
        let mut offset = self.snd_nxt.wrapping_sub(self.snd_una) as usize;
        // A window of one byte when nothing is in flight probes a peer that closed its window.
        let window = self.peer_window.max(if offset == 0 { 1 } else { 0 });
        while offset < self.send_buffer.len() && offset < window {
            // At least one byte, so no MSS can spin this loop with the stack locked.
            let length = MSS.min(self.peer_mss).min(self.send_buffer.len() - offset).min(window - offset).max(1);
            let payload = range(&self.send_buffer, offset, length);
            self.send_parts(wire, ACK | PSH, self.snd_una.wrapping_add(offset as u32), payload, &[]);
            offset += length;
        }
        if self.app_closed && !self.fin_acked && offset == self.send_buffer.len() {
            self.send(wire, FIN | ACK, self.snd_una.wrapping_add(offset as u32), &[], &[]);
            offset += 1;
        }
        let was_idle = self.snd_nxt == self.snd_una;
        self.snd_nxt = self.snd_una.wrapping_add(offset as u32);
        if self.snd_nxt.wrapping_sub(self.snd_max) as i32 > 0 {
            self.snd_max = self.snd_nxt;
        }
        if was_idle && offset > 0 {
            self.arm();
        }
    }

    fn retransmit_first(&self, wire: &mut Wire) {
        if self.send_buffer.is_empty() {
            if self.app_closed && !self.fin_acked {
                self.send(wire, FIN | ACK, self.snd_una, &[], &[]);
            }
        } else {
            let first = range(&self.send_buffer, 0, self.send_buffer.len().min(MSS.min(self.peer_mss)));
            self.send_parts(wire, ACK | PSH, self.snd_una, first, &[]);
        }
    }

    /// Retransmission timeout: go back to the first unacknowledged byte and resend from there.
    /// ponytail: no congestion control, since the traffic is mostly SSH over one gateway hop; add
    /// NewReno here if bulk transfers over a congested link matter.
    fn timeout(&mut self, wire: &mut Wire) {
        self.retries += 1;
        self.rto = (self.rto * 2.0).min(30.0);
        if self.state == State::Connecting {
            if self.retries >= 6 {
                return self.close(wire, "connection timed out", false);
            }
            self.send_syn(wire);
            return self.arm();
        }
        if self.snd_nxt == self.snd_una {
            return;
        }
        if self.retries >= 10 {
            return self.close(wire, "connection timed out", true);
        }
        self.snd_nxt = self.snd_una;
        self.flush(wire);
        self.arm();
    }

    fn finish_if_done(&mut self, wire: &mut Wire) {
        if self.state == State::Open && self.fin_acked && self.peer_closed && self.to_app.is_empty() {
            self.close(wire, "closed", false);
        }
    }

    fn close(&mut self, wire: &mut Wire, reason: &str, reset: bool) {
        match self.state {
            State::Closed => return,
            State::Open => {
                if reset {
                    self.send(wire, RST | ACK, self.snd_nxt, &[], &[]);
                }
                // Wakes both pump threads; the app reads end-of-file.
                let _ = self.app.shutdown(Shutdown::Both);
            }
            State::Connecting => {}
        }
        self.state = State::Closed;
        wire.reaped = true;
        self.deadline = None;
        if let Some(connected) = self.connected.take() {
            let _ = connected.send(Err(reason.to_string()));
        }
    }

    fn arm(&mut self) {
        self.deadline = Some(Instant::now() + Duration::from_secs_f64(self.rto));
    }

    fn send(&self, wire: &mut Wire, flags: u8, seq: u32, payload: &[u8], options: &[u8]) {
        self.send_parts(wire, flags, seq, [payload, &[]], options)
    }

    /// The payload in two parts, as a ring buffer holds it; one segment all the same.
    fn send_parts(&self, wire: &mut Wire, flags: u8, seq: u32, payload: [&[u8]; 2], options: &[u8]) {
        let room = RECEIVE_CAPACITY - self.to_app.len();
        let window = match self.state {
            State::Connecting => 65535,
            _ if self.scaled => (room >> WINDOW_SHIFT).min(65535),
            _ => room.min(65535),
        };
        let mut packet = Vec::with_capacity(40 + options.len() + payload[0].len() + payload[1].len());
        packet.extend([0; 20]); // the IP header, filled in by emit
        packet.extend(self.local_port.to_be_bytes());
        packet.extend(self.remote_port.to_be_bytes());
        packet.extend(seq.to_be_bytes());
        packet.extend(self.rcv_nxt.to_be_bytes());
        packet.extend([(((20 + options.len()) / 4) << 4) as u8, flags]);
        packet.extend((window as u16).to_be_bytes());
        packet.extend([0, 0, 0, 0]);
        packet.extend(options);
        packet.extend(payload[0]);
        packet.extend(payload[1]);
        let sum = checksum_of(&[&pseudo_header(wire.address, self.remote, 6, packet.len() - 20), &packet[20..]]);
        packet[36..38].copy_from_slice(&sum.to_be_bytes());
        wire.emit(self.remote, 6, packet);
    }
}

/// `length` bytes of `buffer` from `offset`, as the two slices the ring holds them in.
fn range(buffer: &VecDeque<u8>, offset: usize, length: usize) -> [&[u8]; 2] {
    let (front, back) = buffer.as_slices();
    if offset >= front.len() {
        let start = offset - front.len();
        [&back[start..start + length], &[]]
    } else if offset + length <= front.len() {
        [&front[offset..offset + length], &[]]
    } else {
        [&front[offset..], &back[..offset + length - front.len()]]
    }
}

fn pseudo_header(source: [u8; 4], destination: [u8; 4], protocol: u8, length: usize) -> [u8; 12] {
    let mut header = [0; 12];
    header[..4].copy_from_slice(&source);
    header[4..8].copy_from_slice(&destination);
    header[9] = protocol;
    header[10..].copy_from_slice(&(length as u16).to_be_bytes());
    header
}

/// The Internet checksum: the ones' complement of the ones' complement sum.
pub fn checksum(bytes: &[u8]) -> u16 {
    checksum_of(&[bytes])
}

/// The same over parts laid end to end. Every part but the last must be of
/// even length, as the pseudo-header is, or the pairing of bytes would shift.
fn checksum_of(parts: &[&[u8]]) -> u16 {
    let mut sum: u32 = parts.iter()
        .flat_map(|part| part.chunks(2))
        .map(|c| (c[0] as u32) << 8 | *c.get(1).unwrap_or(&0) as u32)
        .sum();
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

pub mod dns {
    use crate::tls::Cursor;
    use crate::Result;
    use std::net::Ipv4Addr;

    pub fn query(name: &str, id: u16) -> Vec<u8> {
        let mut message = [&id.to_be_bytes()[..], &[0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]].concat();
        for label in name.split('.').filter(|l| !l.is_empty()) {
            message.push(label.len() as u8);
            message.extend(label.as_bytes());
        }
        message.extend([0, 0, 1, 0, 1]);
        message
    }

    /// The first A record in a reply to query `id`.
    pub fn first_address(reply: &[u8], id: u16) -> Option<Ipv4Addr> {
        answer(reply, id).ok().flatten()
    }

    fn answer(reply: &[u8], id: u16) -> Result<Option<Ipv4Addr>> {
        let mut c = Cursor(reply);
        let flags = if c.u16()? == id { c.u16()? } else { return Ok(None) };
        if flags & 0x8000 == 0 || flags & 0x000F != 0 {
            return Ok(None);
        }
        let (questions, answers) = (c.u16()?, c.u16()?);
        c.take(4)?;
        for _ in 0..questions {
            skip_name(&mut c)?;
            c.take(4)?;
        }
        for _ in 0..answers {
            skip_name(&mut c)?;
            let kind = c.u16()?;
            c.take(6)?;
            let length = c.u16()? as usize;
            let data = c.take(length)?;
            if kind == 1 && length == 4 {
                return Ok(Some(Ipv4Addr::new(data[0], data[1], data[2], data[3])));
            }
        }
        Ok(None)
    }

    fn skip_name(c: &mut Cursor) -> Result<()> {
        loop {
            let length = c.u8()?;
            if length == 0 {
                return Ok(());
            }
            if length & 0xC0 == 0xC0 {
                c.u8()?;
                return Ok(());
            }
            c.take(length as usize)?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn dns_answers_are_found_past_the_question_and_a_cname() {
        let query = dns::query("git.example.edu.cn", 0x1234);
        let mut reply = vec![0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0];
        reply.extend(&query[12..]);
        reply.extend([0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xC0, 0x0C]); // CNAME
        reply.extend([0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 20, 30, 40]); // A
        assert_eq!(dns::first_address(&reply, 0x1234), Some(Ipv4Addr::new(10, 20, 30, 40)));
        assert_eq!(dns::first_address(&reply, 0x9999), None);
    }

    /// The headers are filled in place now, and the checksums summed in parts:
    /// each must still check out as zero over what it covers.
    #[test]
    fn outgoing_packets_carry_valid_checksums() {
        let (packets, arrived) = mpsc::channel();
        let stack = Stack::new([10, 0, 0, 1], move |p| drop(packets.send(p)));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let _user = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let app = Socket::from(listener.accept().unwrap().0);
        let connecting = stack.clone();
        thread::spawn(move || drop(connecting.connect(Ipv4Addr::new(10, 0, 0, 2), 22, &app)));
        let syn = arrived.recv_timeout(Duration::from_secs(5)).unwrap();
        let asking = stack.clone();
        thread::spawn(move || asking.exchange(b"odd", Ipv4Addr::new(10, 0, 0, 3), 53, Duration::from_millis(50)));
        let datagram = arrived.recv_timeout(Duration::from_secs(5)).unwrap();
        for (packet, protocol, remote) in [(syn, 6, [10, 0, 0, 2]), (datagram, 17, [10, 0, 0, 3])] {
            assert_eq!(u16::from_be_bytes([packet[2], packet[3]]) as usize, packet.len());
            assert_eq!((packet[9], &packet[16..20]), (protocol, &remote[..]));
            assert_eq!(checksum(&packet[..20]), 0);
            assert_eq!(checksum(&[&pseudo_header([10, 0, 0, 1], remote, protocol, packet.len() - 20)[..], &packet[20..]].concat()), 0);
        }
        stack.stop();
    }

    #[test]
    fn a_range_of_a_wrapped_ring_comes_back_in_order() {
        let mut ring = VecDeque::with_capacity(8);
        ring.extend([0u8; 7]);
        ring.drain(..6);
        ring.extend(2..=8u8);
        assert!(!ring.as_slices().1.is_empty(), "the ring should wrap");
        for (offset, length) in [(0, 8), (1, 3), (5, 3), (2, 6), (7, 1)] {
            let [front, back] = range(&ring, offset, length);
            assert_eq!([front, back].concat(), ring.range(offset..offset + length).copied().collect::<Vec<_>>());
        }
    }

    /// A connection through the stack to a scripted peer that echoes what it
    /// receives and loses the first data segment, so the bytes arrive only if
    /// the retransmission timer works.
    #[test]
    fn a_connection_carries_bytes_both_ways_and_survives_a_lost_segment() {
        let (packets, arrived) = mpsc::channel();
        let stack = Stack::new([10, 0, 0, 1], move |p| drop(packets.send(p)));
        let dropped = Arc::new(AtomicUsize::new(0));
        let (peer, lost) = (stack.clone(), dropped.clone());
        thread::spawn(move || echo_peer(&peer, arrived, &lost));

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut user = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let app = Socket::from(listener.accept().unwrap().0);
        let link = stack.connect(Ipv4Addr::new(10, 0, 0, 2), 22, &app).unwrap();
        let pumping = stack.clone();
        thread::spawn(move || pumping.pump(link, app));

        user.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let message = b"hello through the tunnel";
        user.write_all(message).unwrap();
        let mut echoed = [0; 24];
        user.read_exact(&mut echoed).unwrap();
        assert_eq!(&echoed, message);
        assert_eq!(dropped.load(Ordering::SeqCst), 1);

        // The peer hangs up after echoing, which reads as end-of-file.
        assert_eq!(user.read(&mut [0; 16]).unwrap(), 0);
        stack.stop();
    }

    /// Segments sent in the order 2, 3, 1. Were the early two dropped, the ACK
    /// after the first would stop at its end and the peer would have to resend.
    #[test]
    fn segments_past_a_gap_are_held_until_it_fills() {
        let (packets, arrived) = mpsc::channel::<Vec<u8>>();
        let stack = Stack::new([10, 0, 0, 1], move |p| drop(packets.send(p)));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut user = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let app = Socket::from(listener.accept().unwrap().0);
        let dialing = stack.clone();
        thread::spawn(move || {
            let link = dialing.connect(Ipv4Addr::new(10, 0, 0, 2), 22, &app).unwrap();
            dialing.pump(link, app);
        });

        let syn = arrived.recv().unwrap();
        let tcp = &syn[20..];
        let ports = (u16::from_be_bytes([tcp[0], tcp[1]]), u16::from_be_bytes([tcp[2], tcp[3]]));
        let ack = u32::from_be_bytes(tcp[4..8].try_into().unwrap()).wrapping_add(1);
        reply(&stack, ports, 5000, ack, SYN | ACK, &[], &[]);
        for (seq, part) in [(5006, &b"second"[..]), (5012, b"third"), (5001, b"first")] {
            reply(&stack, ports, seq, ack, ACK | PSH, part, &[]);
        }
        let acks: Vec<u32> = arrived.try_iter().map(|p| u32::from_be_bytes(p[28..32].try_into().unwrap())).collect();
        assert_eq!(acks.last(), Some(&5017));

        user.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut received = [0; 16];
        user.read_exact(&mut received).unwrap();
        assert_eq!(&received, b"firstsecondthird");
        stack.stop();
    }

    /// Were an MSS of zero taken at its word, the first write would spin
    /// forever sending empty segments with the stack locked.
    #[test]
    fn a_peer_advertising_an_mss_of_zero_still_gets_the_data() {
        let (packets, arrived) = mpsc::channel::<Vec<u8>>();
        let stack = Stack::new([10, 0, 0, 1], move |p| drop(packets.send(p)));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut user = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let app = Socket::from(listener.accept().unwrap().0);
        let dialing = stack.clone();
        thread::spawn(move || {
            let link = dialing.connect(Ipv4Addr::new(10, 0, 0, 2), 22, &app).unwrap();
            dialing.pump(link, app);
        });

        let syn = arrived.recv().unwrap();
        let tcp = &syn[20..];
        let ports = (u16::from_be_bytes([tcp[0], tcp[1]]), u16::from_be_bytes([tcp[2], tcp[3]]));
        let ack = u32::from_be_bytes(tcp[4..8].try_into().unwrap()).wrapping_add(1);
        // Written before the handshake completes, so the pump reads it in one go.
        user.write_all(&[7; 1000]).unwrap();
        reply(&stack, ports, 5000, ack, SYN | ACK, &[], &[2, 4, 0, 0]);

        let (mut sizes, deadline) = (vec![], Instant::now() + Duration::from_secs(5));
        while sizes.iter().sum::<usize>() < 1000 {
            assert!(Instant::now() < deadline, "the data never arrived");
            let packet = arrived.recv_timeout(Duration::from_secs(5)).expect("the data never arrived");
            let tcp = &packet[20..];
            let payload = tcp.len() - (tcp[12] >> 4) as usize * 4;
            if payload > 0 {
                sizes.push(payload);
            }
        }
        assert_eq!(sizes, [536, 464], "the default MSS applies");
        stack.stop();
    }

    #[test]
    fn a_refused_connection_says_so() {
        let (packets, arrived) = mpsc::channel::<Vec<u8>>();
        let stack = Stack::new([10, 0, 0, 1], move |p| drop(packets.send(p)));
        let peer = stack.clone();
        thread::spawn(move || {
            for packet in arrived {
                let tcp = &packet[20..];
                let seq = u32::from_be_bytes(tcp[4..8].try_into().unwrap());
                reply(&peer, (u16::from_be_bytes([tcp[0], tcp[1]]), u16::from_be_bytes([tcp[2], tcp[3]])), 0, seq.wrapping_add(1), RST | ACK, &[], &[]);
            }
        });
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let _user = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let app = Socket::from(listener.accept().unwrap().0);
        assert_eq!(stack.connect(Ipv4Addr::new(10, 0, 0, 2), 22, &app).err().as_deref(), Some("connection refused"));
        stack.stop();
    }

    /// The far end of a TCP connection: accepts, echoes, closes after echoing, and
    /// loses the first data segment it sees.
    fn echo_peer(stack: &Stack, packets: mpsc::Receiver<Vec<u8>>, dropped: &AtomicUsize) {
        let (mut seq, mut expected) = (5000u32, 0u32);
        for packet in packets {
            let tcp = &packet[20..];
            let flags = tcp[13];
            let their_seq = u32::from_be_bytes(tcp[4..8].try_into().unwrap());
            let payload = &tcp[(tcp[12] >> 4) as usize * 4..];
            let ports = (u16::from_be_bytes([tcp[0], tcp[1]]), u16::from_be_bytes([tcp[2], tcp[3]]));

            if flags & SYN != 0 {
                expected = their_seq.wrapping_add(1);
                reply(stack, ports, seq, expected, SYN | ACK, &[], &[2, 4, 0x05, 0x50]);
                seq += 1;
            } else if !payload.is_empty() {
                if dropped.load(Ordering::SeqCst) == 0 {
                    dropped.store(1, Ordering::SeqCst);
                    continue;
                }
                if their_seq != expected {
                    reply(stack, ports, seq, expected, ACK, &[], &[]);
                    continue;
                }
                expected += payload.len() as u32;
                reply(stack, ports, seq, expected, ACK | PSH, payload, &[]);
                seq += payload.len() as u32;
                reply(stack, ports, seq, expected, FIN | ACK, &[], &[]);
                seq += 1;
            } else if flags & FIN != 0 {
                expected += 1;
                reply(stack, ports, seq, expected, ACK, &[], &[]);
            }
        }
    }

    fn reply(stack: &Stack, ports: (u16, u16), seq: u32, ack: u32, flags: u8, payload: &[u8], options: &[u8]) {
        let mut segment = [&ports.1.to_be_bytes()[..], &ports.0.to_be_bytes(), &seq.to_be_bytes(), &ack.to_be_bytes(),
            &[(((20 + options.len()) / 4) << 4) as u8, flags, 0xFF, 0xFF, 0, 0, 0, 0], options, payload].concat();
        let sum = checksum(&[&pseudo_header([10, 0, 0, 2], [10, 0, 0, 1], 6, segment.len())[..], &segment].concat());
        segment[16..18].copy_from_slice(&sum.to_be_bytes());
        let mut ip = [&[0x45, 0][..], &((20 + segment.len()) as u16).to_be_bytes(), &[0, 0, 0x40, 0, 64, 6, 0, 0, 10, 0, 0, 2, 10, 0, 0, 1]].concat();
        let sum = checksum(&ip);
        ip[10..12].copy_from_slice(&sum.to_be_bytes());
        stack.receive(&[ip, segment].concat());
    }
}
