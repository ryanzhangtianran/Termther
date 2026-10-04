//! termther-ec: logs in to a Sangfor EasyConnect gateway and serves the tunnel
//! as a SOCKS5 proxy on loopback. Only traffic sent to the proxy goes through
//! the tunnel.

use socket2::Socket;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::process::{exit, Command};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use termther_ec::gateway::Underlay;
use termther_ec::session::{Credentials, Session};
use termther_ec::{bail, Result};

const USAGE: &str = "\
usage: termther-ec GATEWAY USER [--listen ADDR] [--interface NAME] [--dns ADDR]

Logs in to an EasyConnect gateway and serves the tunnel as a SOCKS5 proxy.

  --listen ADDR     where to serve SOCKS5 (default 127.0.0.1:1080)
  --interface NAME  bind the gateway connection to this interface, e.g. eth0
  --dns ADDR        resolve the gateway's name with this server

The password comes from TERMTHER_EC_PASSWORD, or is asked for.
TERMTHER_EC_TOTP holds the base32 TOTP secret when the account has a second
factor.";

type Current = Arc<Mutex<Option<Arc<Session>>>>;

fn main() {
    let mut args = std::env::args().skip(1);
    let (mut positional, mut listen, mut underlay) = (vec![], "127.0.0.1:1080".to_string(), Underlay::default());
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--listen" => listen = args.next().unwrap_or_else(|| usage()),
            "--interface" => underlay.interface = Some(args.next().unwrap_or_else(|| usage())),
            "--dns" => underlay.dns = Some(args.next().unwrap_or_else(|| usage())),
            _ if arg.starts_with('-') => usage(),
            _ => positional.push(arg),
        }
    }
    let [gateway, username] = <[String; 2]>::try_from(positional).unwrap_or_else(|_| usage());
    let password = std::env::var("TERMTHER_EC_PASSWORD").ok().filter(|p| !p.is_empty()).unwrap_or_else(|| prompt("password: "));
    let credentials = Credentials { username, password, totp_secret: std::env::var("TERMTHER_EC_TOTP").ok() };

    let listener = TcpListener::bind(&listen).unwrap_or_else(|e| {
        eprintln!("listen on {listen}: {e}");
        exit(1)
    });
    let current = Current::default();
    let serving = current.clone();
    thread::spawn(move || {
        for client in listener.incoming().flatten() {
            let current = serving.clone();
            thread::spawn(move || {
                if let Err(e) = socks(client, &current) {
                    eprintln!("socks: {e}");
                }
            });
        }
    });

    // Logs in, and again whenever the tunnel breaks for good. A first login
    // that fails ends here instead: retrying a wrong password locks accounts.
    let mut connected = false;
    loop {
        match Session::open(&gateway, &credentials, underlay.clone()) {
            Ok(session) => {
                connected = true;
                let routing = &session.routing;
                eprintln!("tunnel up as {}; SOCKS5 on {listen}", session.address);
                for r in &routing.ip {
                    eprintln!("  route {} {}-{} ports {}-{}", r.protocol, r.from, r.to, r.port_min, r.port_max);
                }
                eprintln!("  {} domains, DNS {}", routing.domains.len(), routing.dns.join(", "));
                *current.lock().unwrap() = Some(session.clone());
                let reason = loop {
                    thread::sleep(Duration::from_secs(5));
                    if let Some(reason) = session.failure() {
                        break reason;
                    }
                };
                eprintln!("tunnel broke: {reason}; logging in again");
                current.lock().unwrap().take();
                session.close();
            }
            Err(e) if !connected => {
                eprintln!("login failed: {e}");
                exit(1)
            }
            Err(e) => eprintln!("login failed: {e}; retrying"),
        }
        thread::sleep(Duration::from_secs(10));
    }
}

fn usage() -> ! {
    eprintln!("{USAGE}");
    exit(2)
}

fn prompt(label: &str) -> String {
    eprint!("{label}");
    let hidden = Command::new("stty").arg("-echo").status().is_ok_and(|s| s.success());
    let mut line = String::new();
    let _ = io::stdin().read_line(&mut line);
    if hidden {
        let _ = Command::new("stty").arg("echo").status();
        eprintln!();
    }
    line.trim_end_matches(['\r', '\n']).to_string()
}

/// Answers one SOCKS5 client, CONNECT only, and pumps it through the tunnel.
///
/// Only the no-authentication method is offered: the listener is meant for
/// loopback, where anything that can reach it can already run code as this user.
fn socks(client: TcpStream, current: &Current) -> Result<()> {
    let client = Socket::from(client);
    let mut s = &client;
    let mut greeting = [0; 2];
    s.read_exact(&mut greeting)?;
    if greeting[0] != 5 {
        bail!("not SOCKS5 (version {})", greeting[0]);
    }
    let mut methods = vec![0; greeting[1] as usize];
    s.read_exact(&mut methods)?;
    if !methods.contains(&0) {
        s.write_all(&[5, 0xFF])?;
        bail!("client offered no acceptable auth method");
    }
    s.write_all(&[5, 0])?;

    let mut request = [0; 4];
    s.read_exact(&mut request)?;
    let host = match request[3] {
        1 => {
            let mut ip = [0; 4];
            s.read_exact(&mut ip)?;
            Ipv4Addr::from(ip).to_string()
        }
        3 => {
            let mut length = [0];
            s.read_exact(&mut length)?;
            let mut name = vec![0; length[0] as usize];
            s.read_exact(&mut name)?;
            String::from_utf8_lossy(&name).into_owned()
        }
        _ => {
            reply(s, 8)?;
            bail!("only IPv4 and names are supported");
        }
    };
    let mut port = [0; 2];
    s.read_exact(&mut port)?;
    let port = u16::from_be_bytes(port);
    if request[0] != 5 || request[1] != 1 {
        reply(s, 7)?;
        bail!("only CONNECT is supported");
    }

    let Some(session) = current.lock().unwrap().clone() else {
        reply(s, 1)?;
        bail!("{host}:{port}: the tunnel is not up");
    };
    match session.dial(&host, port, &client) {
        Ok(link) => {
            if let Err(e) = reply(s, 0) {
                // The client left while the tunnel dialled; no pump will ever end the connection.
                session.stack.abort(link);
                return Err(e);
            }
            session.stack.pump(link, client);
            Ok(())
        }
        Err(e) => {
            reply(s, if e.to_string().contains("refused") { 5 } else { 4 })?;
            Err(e)
        }
    }
}

fn reply(mut s: &Socket, code: u8) -> Result<()> {
    Ok(s.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0])?)
}
