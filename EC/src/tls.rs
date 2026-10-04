//! Just enough TLS to talk to a Sangfor gateway.
//!
//! The gateway needs two things that no TLS library offers. First, a
//! ClientHello with a chosen session ID: "L3IP" and zeros is how the gateway
//! tells a tunnel apart from its web portal, which listens on the same port,
//! and it only accepts TLS 1.1 with RC4. Second, the session ID the server
//! returns on an ordinary handshake, which becomes half of the tunnel token.
//!
//! It supports RSA key exchange only, with RC4-SHA or AES-CBC-SHA, over TLS
//! 1.1 or 1.2. The certificate is not verified, as in every EasyConnect client:
//! campus gateways often present certificates that would fail validation.

use crate::{Error, Result};
use aes::cipher::{generic_array::GenericArray, BlockDecrypt, BlockEncrypt, KeyInit};
use aes::{Aes128, Aes256};
use hmac::digest::{core_api::BlockSizeUser, Digest};
use hmac::{Mac, SimpleHmac};
use md5::Md5;
use rand::RngCore;
use rsa::pkcs8::DecodePublicKey;
use rsa::{Pkcs1v15Encrypt, RsaPublicKey};
use sha1::Sha1;
use sha2::Sha256;
use std::io::{BufReader, Read, Write};
use std::net::{Ipv4Addr, TcpStream};

pub enum Hello<'a> {
    /// The tunnel's hello: TLS 1.1, RC4, session ID "L3IP".
    Tunnel,
    /// An ordinary TLS 1.2 hello, for the portal.
    Portal { server_name: &'a str },
}

pub struct Tls {
    /// Buffered for reading, so a record is one `recv` rather than two; writes
    /// go to the socket underneath.
    stream: BufReader<TcpStream>,
    /// The session ID from the ServerHello.
    pub session_id: Vec<u8>,
    version: u16,
    reader: Option<Cipher>,
    writer: Option<Cipher>,
    pending: Vec<u8>,
}

impl Tls {
    pub fn handshake(stream: TcpStream, hello: Hello) -> Result<Tls> {
        let stream = BufReader::with_capacity(32 * 1024, stream);
        let mut tls = Tls { stream, session_id: vec![], version: 0x0301, reader: None, writer: None, pending: vec![] };
        tls.run(hello)?;
        Ok(tls)
    }

    /// The underlying socket, for timeouts and for shutting it down from another thread.
    pub fn socket(&self) -> &TcpStream {
        self.stream.get_ref()
    }

    fn run(&mut self, hello: Hello) -> Result<()> {
        let client_random = random(32);
        let (offered, session_id, suites, extensions): (u16, Vec<u8>, &[u16], Vec<u8>) = match hello {
            Hello::Tunnel => (
                0x0302,
                [&b"L3IP"[..], &[0; 28]].concat(),
                &[0x0005, 0x00FF], // RC4_128_SHA, EMPTY_RENEGOTIATION_INFO_SCSV
                // A heartbeat extension. The gateway expects it even though
                // heartbeats are never sent.
                vec![0x00, 0x0F, 0x00, 0x01, 0x01],
            ),
            Hello::Portal { server_name } => {
                // signature_algorithms: rsa_pkcs1_sha256, rsa_pkcs1_sha1.
                let mut extensions = vec![0x00, 0x0D, 0x00, 0x06, 0x00, 0x04, 0x04, 0x01, 0x02, 0x01];
                if server_name.parse::<Ipv4Addr>().is_err() {
                    let name = server_name.as_bytes();
                    extensions.extend([0, 0]);
                    extensions.extend(be16(name.len() + 5));
                    extensions.extend(be16(name.len() + 3));
                    extensions.push(0);
                    extensions.extend(be16(name.len()));
                    extensions.extend(name);
                }
                // AES_128_CBC_SHA, AES_256_CBC_SHA, RC4
                (0x0303, vec![], &[0x002F, 0x0035, 0x0005, 0x00FF], extensions)
            }
        };

        let mut body = offered.to_be_bytes().to_vec();
        body.extend(&client_random);
        body.push(session_id.len() as u8);
        body.extend(&session_id);
        body.extend(be16(suites.len() * 2));
        suites.iter().for_each(|s| body.extend(s.to_be_bytes()));
        body.extend([0x01, 0x00]); // compression: null only
        body.extend(be16(extensions.len()));
        body.extend(&extensions);
        let mut transcript = handshake_message(1, &body);
        self.write_record(22, &transcript)?;

        // ServerHello
        let (_, server_hello, raw) = self.read_handshake(Some(2))?;
        transcript.extend(raw);
        let mut cursor = Cursor(&server_hello);
        self.version = cursor.u16()?;
        if !(self.version == 0x0302 || self.version == 0x0303) || self.version > offered {
            bail!("TLS: server chose version {:04x}", self.version);
        }
        let server_random = cursor.take(32)?.to_vec();
        let length = cursor.u8()? as usize;
        self.session_id = cursor.take(length)?.to_vec();
        let suite = cursor.u16()?;
        if !suites.contains(&suite) || suite == 0x00FF {
            bail!("TLS: server chose cipher {suite:04x}");
        }

        // Certificate, then ServerHelloDone.
        let mut certificate = None;
        loop {
            let (kind, body, raw) = self.read_handshake(None)?;
            transcript.extend(raw);
            match kind {
                11 => {
                    let mut certs = Cursor(&body);
                    certs.take(3)?;
                    let length = certs.u24()? as usize;
                    certificate = Some(certs.take(length)?.to_vec());
                }
                14 => break,
                13 => bail!("TLS: gateway asks for a client certificate"),
                other => bail!("TLS: unexpected handshake message {other}"),
            }
        }
        let key = certificate
            .as_deref()
            .and_then(public_key_info)
            .and_then(|der| RsaPublicKey::from_public_key_der(der).ok())
            .ok_or("TLS: unreadable server certificate")?;

        // ClientKeyExchange: a premaster secret, encrypted to the certificate.
        let mut premaster = offered.to_be_bytes().to_vec();
        premaster.extend(random(46));
        let sealed = rsa_encrypt(&key, &premaster)?;
        let exchange = handshake_message(16, &[&be16(sealed.len())[..], &sealed].concat());
        transcript.extend(&exchange);
        self.write_record(22, &exchange)?;

        let master = prf(self.version, &premaster, "master secret", &[&client_random[..], &server_random].concat(), 48);
        let key_length = if suite == 0x0035 { 32 } else { 16 };
        let block = prf(self.version, &master, "key expansion", &[&server_random[..], &client_random].concat(), 40 + 2 * key_length);
        let (client_mac, server_mac) = (&block[0..20], &block[20..40]);
        let (client_key, server_key) = (&block[40..40 + key_length], &block[40 + key_length..]);
        let rc4 = suite == 0x0005;

        self.write_record(20, &[1])?;
        self.writer = Some(Cipher::new(client_key, client_mac, rc4));
        let finished = handshake_message(20, &prf(self.version, &master, "client finished", &self.transcript_hash(&transcript), 12));
        transcript.extend(&finished);
        self.write_record(22, &finished)?;

        let (kind, _) = self.read_record()?;
        if kind != 20 {
            bail!("TLS: expected ChangeCipherSpec, got {kind}");
        }
        self.reader = Some(Cipher::new(server_key, server_mac, rc4));
        let (_, server_finished, _) = self.read_handshake(Some(20))?;
        if server_finished != prf(self.version, &master, "server finished", &self.transcript_hash(&transcript), 12) {
            bail!("TLS: server Finished does not verify");
        }
        Ok(())
    }

    /// Sends `bytes` as application data, in as few records as possible.
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        self.write_each([bytes])
    }

    /// Sends each message as application data in records of its own, all in
    /// one write. The tunnel needs one packet per record.
    pub fn write_each<'a>(&mut self, messages: impl IntoIterator<Item = &'a [u8]>) -> Result<()> {
        let mut records = vec![];
        for message in messages {
            for chunk in message.chunks(16384) {
                self.append_record(23, chunk, &mut records);
            }
        }
        Ok(self.stream.get_mut().write_all(&records)?)
    }

    /// The payload of the next application-data record. The tunnel sends one
    /// IP packet per record, so record boundaries matter.
    pub fn read(&mut self) -> Result<Vec<u8>> {
        loop {
            let (kind, payload) = self.read_record()?;
            if kind == 23 {
                return Ok(payload);
            }
            // Anything else after the handshake, such as a HelloRequest, is ignored.
        }
    }

    fn write_record(&mut self, kind: u8, payload: &[u8]) -> Result<()> {
        let mut record = vec![];
        self.append_record(kind, payload, &mut record);
        Ok(self.stream.get_mut().write_all(&record)?)
    }

    /// One record onto the end of `out`, sealed in place.
    fn append_record(&mut self, kind: u8, payload: &[u8], out: &mut Vec<u8>) {
        let start = out.len();
        out.reserve(5 + 16 + payload.len() + 20 + 16);
        out.push(kind);
        out.extend(self.version.to_be_bytes());
        out.extend([0, 0]);
        match &mut self.writer {
            Some(writer) => writer.seal(kind, self.version, payload, out),
            None => out.extend_from_slice(payload),
        }
        let length = be16(out.len() - start - 5);
        out[start + 3..start + 5].copy_from_slice(&length);
    }

    fn read_record(&mut self) -> Result<(u8, Vec<u8>)> {
        let mut header = [0; 5];
        self.stream.read_exact(&mut header)?;
        let length = u16::from_be_bytes([header[3], header[4]]) as usize;
        if length > 18432 {
            bail!("TLS: oversized record");
        }
        let mut payload = vec![0; length];
        self.stream.read_exact(&mut payload)?;
        if let Some(reader) = &mut self.reader {
            reader.open(header[0], self.version, &mut payload)?;
        }
        if header[0] == 21 && payload.len() == 2 {
            return Err(if payload[1] == 0 { Error::Closed } else { format!("TLS alert {}", payload[1]).into() });
        }
        Ok((header[0], payload))
    }

    /// (type, body, the whole message as it goes into the transcript)
    fn read_handshake(&mut self, expected: Option<u8>) -> Result<(u8, Vec<u8>, Vec<u8>)> {
        loop {
            if self.pending.len() >= 4 {
                let length = u32::from_be_bytes([0, self.pending[1], self.pending[2], self.pending[3]]) as usize;
                if self.pending.len() >= 4 + length {
                    let raw: Vec<u8> = self.pending.drain(..4 + length).collect();
                    if let Some(expected) = expected.filter(|&e| e != raw[0]) {
                        bail!("TLS: expected handshake message {expected}, got {}", raw[0]);
                    }
                    return Ok((raw[0], raw[4..].to_vec(), raw));
                }
            }
            let (kind, payload) = self.read_record()?;
            if kind != 22 {
                bail!("TLS: expected handshake, got record {kind}");
            }
            self.pending.extend(payload);
        }
    }

    fn transcript_hash(&self, transcript: &[u8]) -> Vec<u8> {
        if self.version >= 0x0303 {
            return Sha256::digest(transcript).to_vec();
        }
        [Md5::digest(transcript).to_vec(), Sha1::digest(transcript).to_vec()].concat()
    }
}

/// The TLS pseudorandom function: P_SHA256 for 1.2, P_MD5 XOR P_SHA1 before it.
fn prf(version: u16, secret: &[u8], label: &str, seed: &[u8], count: usize) -> Vec<u8> {
    let seed = [label.as_bytes(), seed].concat();
    if version >= 0x0303 {
        return p_hash(hmac::<Sha256>, secret, &seed, count);
    }
    let half = secret.len().div_ceil(2);
    let md5 = p_hash(hmac::<Md5>, &secret[..half], &seed, count);
    let sha1 = p_hash(hmac::<Sha1>, &secret[secret.len() - half..], &seed, count);
    md5.iter().zip(sha1).map(|(a, b)| a ^ b).collect()
}

fn p_hash(mac: fn(&[u8], &[u8]) -> Vec<u8>, secret: &[u8], seed: &[u8], count: usize) -> Vec<u8> {
    let mut output = vec![];
    let mut a = seed.to_vec();
    while output.len() < count {
        a = mac(secret, &a);
        output.extend(mac(secret, &[&a[..], seed].concat()));
    }
    output.truncate(count);
    output
}

pub fn hmac<D: Digest + BlockSizeUser>(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = <SimpleHmac<D> as Mac>::new_from_slice(key).expect("HMAC takes a key of any length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// PKCS#1 v1.5 encryption.
pub fn rsa_encrypt(key: &RsaPublicKey, plain: &[u8]) -> Result<Vec<u8>> {
    key.encrypt(&mut rand::thread_rng(), Pkcs1v15Encrypt, plain)
        .map_err(|e| format!("RSA: {e}").into())
}

/// The SubjectPublicKeyInfo inside a DER certificate, found by walking the
/// fields that precede it rather than parsing the whole thing.
fn public_key_info(certificate: &[u8]) -> Option<&[u8]> {
    let (_, certificate, _) = der(certificate)?;
    let (_, mut tbs, _) = der(certificate)?;
    if tbs.first() == Some(&0xA0) {
        tbs = der(tbs)?.2; // version
    }
    for _ in 0..5 {
        tbs = der(tbs)?.2; // serial, signature, issuer, validity, subject
    }
    let (_, _, rest) = der(tbs)?;
    Some(&tbs[..tbs.len() - rest.len()])
}

/// One DER element: (tag, content, what follows).
fn der(bytes: &[u8]) -> Option<(u8, &[u8], &[u8])> {
    let (&tag, bytes) = bytes.split_first()?;
    let (&first, mut bytes) = bytes.split_first()?;
    let length = if first < 0x80 {
        first as usize
    } else {
        let n = (first & 0x7F) as usize;
        if n > 4 || bytes.len() < n {
            return None;
        }
        let length = bytes[..n].iter().fold(0, |sum, &b| sum << 8 | b as usize);
        bytes = &bytes[n..];
        length
    };
    (bytes.len() >= length).then(|| (tag, &bytes[..length], &bytes[length..]))
}

/// Record protection for one direction: RC4 or AES-CBC, each with HMAC-SHA1.
struct Cipher {
    key: Vec<u8>,
    /// Keyed once, and cloned for each record.
    mac: SimpleHmac<Sha1>,
    rc4: Option<Rc4>,
    sequence: u64,
}

impl Cipher {
    fn new(key: &[u8], mac_key: &[u8], rc4: bool) -> Cipher {
        let mac = <SimpleHmac<Sha1> as Mac>::new_from_slice(mac_key).expect("HMAC takes a key of any length");
        Cipher { key: key.to_vec(), mac, rc4: rc4.then(|| Rc4::new(key)), sequence: 0 }
    }

    /// The record MAC, fed in parts rather than over a copy of the content.
    fn mac(&self, kind: u8, version: u16, content: &[u8]) -> [u8; 20] {
        let mut mac = self.mac.clone();
        mac.update(&self.sequence.to_be_bytes());
        mac.update(&[kind]);
        mac.update(&version.to_be_bytes());
        mac.update(&be16(content.len()));
        mac.update(content);
        mac.finalize().into_bytes().into()
    }

    /// Appends the sealed body of a record to `out`, encrypted in place there.
    fn seal(&mut self, kind: u8, version: u16, plain: &[u8], out: &mut Vec<u8>) {
        let tag = self.mac(kind, version, plain);
        self.sequence += 1;
        if let Some(rc4) = &mut self.rc4 {
            let start = out.len();
            out.extend_from_slice(plain);
            out.extend_from_slice(&tag);
            rc4.apply(&mut out[start..]);
            return;
        }
        let iv = random(16);
        out.extend_from_slice(&iv);
        let start = out.len();
        out.extend_from_slice(plain);
        out.extend_from_slice(&tag);
        let pad = 15 - (out.len() - start) % 16;
        out.extend(std::iter::repeat_n(pad as u8, pad + 1));
        cbc(&self.key, &iv, &mut out[start..], true);
    }

    /// Opens `record` in place, leaving the plaintext.
    fn open(&mut self, kind: u8, version: u16, record: &mut Vec<u8>) -> Result<()> {
        if let Some(rc4) = &mut self.rc4 {
            rc4.apply(record);
        } else {
            if record.len() < 32 || !record.len().is_multiple_of(16) {
                bail!("TLS: malformed CBC record");
            }
            let iv: [u8; 16] = record[..16].try_into().unwrap();
            cbc(&self.key, &iv, &mut record[16..], false);
            record.drain(..16);
            let pad = record[record.len() - 1] as usize;
            if pad + 21 > record.len() {
                bail!("TLS: bad padding");
            }
            record.truncate(record.len() - pad - 1);
        }
        if record.len() < 20 {
            bail!("TLS: short record");
        }
        let length = record.len() - 20;
        if record[length..] != self.mac(kind, version, &record[..length]) {
            bail!("TLS: bad record MAC");
        }
        self.sequence += 1;
        record.truncate(length);
        Ok(())
    }
}

/// RC4, which the tunnel requires. It is broken as a cipher, but the gateway accepts nothing else.
struct Rc4 {
    s: [u8; 256],
    i: u8,
    j: u8,
}

impl Rc4 {
    fn new(key: &[u8]) -> Rc4 {
        let mut s = [0u8; 256];
        s.iter_mut().enumerate().for_each(|(i, x)| *x = i as u8);
        let mut j = 0u8;
        for i in 0..256 {
            j = j.wrapping_add(s[i]).wrapping_add(key[i % key.len()]);
            s.swap(i, j as usize);
        }
        Rc4 { s, i: 0, j: 0 }
    }

    fn apply(&mut self, data: &mut [u8]) {
        for byte in data {
            self.i = self.i.wrapping_add(1);
            self.j = self.j.wrapping_add(self.s[self.i as usize]);
            self.s.swap(self.i as usize, self.j as usize);
            *byte ^= self.s[self.s[self.i as usize].wrapping_add(self.s[self.j as usize]) as usize];
        }
    }
}

fn cbc(key: &[u8], iv: &[u8], data: &mut [u8], encrypt: bool) {
    match key.len() {
        16 => cbc_with(&Aes128::new_from_slice(key).unwrap(), iv, data, encrypt),
        _ => cbc_with(&Aes256::new_from_slice(key).unwrap(), iv, data, encrypt),
    }
}

fn cbc_with<C: BlockEncrypt + BlockDecrypt>(cipher: &C, iv: &[u8], data: &mut [u8], encrypt: bool) {
    let mut previous: [u8; 16] = iv.try_into().unwrap();
    for block in data.chunks_exact_mut(16) {
        if encrypt {
            block.iter_mut().zip(previous).for_each(|(b, p)| *b ^= p);
            cipher.encrypt_block(GenericArray::from_mut_slice(block));
            previous.copy_from_slice(block);
        } else {
            let saved: [u8; 16] = (*block).try_into().unwrap();
            cipher.decrypt_block(GenericArray::from_mut_slice(block));
            block.iter_mut().zip(previous).for_each(|(b, p)| *b ^= p);
            previous = saved;
        }
    }
}

fn handshake_message(kind: u8, body: &[u8]) -> Vec<u8> {
    let length = (body.len() as u32).to_be_bytes();
    [&[kind, length[1], length[2], length[3]][..], body].concat()
}

pub fn be16(value: usize) -> [u8; 2] {
    (value as u16).to_be_bytes()
}

pub fn random(count: usize) -> Vec<u8> {
    let mut bytes = vec![0; count];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes
}

/// Reads big-endian fields off the front of a byte slice.
pub struct Cursor<'a>(pub &'a [u8]);

impl<'a> Cursor<'a> {
    pub fn take(&mut self, count: usize) -> Result<&'a [u8]> {
        if count > self.0.len() {
            bail!("truncated message");
        }
        let (head, rest) = self.0.split_at(count);
        self.0 = rest;
        Ok(head)
    }
    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    pub fn u16(&mut self) -> Result<u16> {
        let b = self.take(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }
    fn u24(&mut self) -> Result<u32> {
        let b = self.take(3)?;
        Ok(u32::from_be_bytes([0, b[0], b[1], b[2]]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Against a local server, run by hand. For the portal hello:
    ///   openssl s_server -accept 4433 -cert c.pem -key k.pem -www -cipher 'AES128-SHA:@SECLEVEL=0'
    /// For the tunnel hello, add `-tls1_1 -cipher 'RC4-SHA:@SECLEVEL=0'` (system LibreSSL: Homebrew's OpenSSL has no RC4).
    ///   TERMTHER_TLS_SERVER=127.0.0.1:4433 [TERMTHER_TLS_TUNNEL=1] cargo test live_tls
    #[test]
    fn live_tls() {
        let Ok(server) = std::env::var("TERMTHER_TLS_SERVER") else { return };
        let hello = match std::env::var("TERMTHER_TLS_TUNNEL") {
            Ok(_) => Hello::Tunnel,
            Err(_) => Hello::Portal { server_name: "localhost" },
        };
        let mut tls = Tls::handshake(TcpStream::connect(server).unwrap(), hello).unwrap();
        tls.write(b"GET / HTTP/1.0\r\n\r\n").unwrap();
        assert!(tls.read().unwrap().starts_with(b"HTTP/1.0 200"));
        assert!(!tls.session_id.is_empty());
    }

    #[test]
    fn rc4_matches_the_rfc_6229_vector() {
        let mut data = [0u8; 8];
        Rc4::new(&[1, 2, 3, 4, 5]).apply(&mut data);
        assert_eq!(data, [0xb2, 0x39, 0x63, 0x05, 0xf0, 0x3d, 0xc0, 0x27]);
    }

    #[test]
    fn a_sealed_record_opens_again() {
        for rc4 in [true, false] {
            let (mut out, mut back) = (Cipher::new(&[7; 16], &[9; 20], rc4), Cipher::new(&[7; 16], &[9; 20], rc4));
            for message in [&b"packet"[..], &[0; 100]] {
                let mut sealed = vec![];
                out.seal(23, 0x0302, message, &mut sealed);
                back.open(23, 0x0302, &mut sealed).unwrap();
                assert_eq!(sealed, message);
            }
        }
    }

    /// The MAC is fed in parts; the record must still be plain, then
    /// HMAC-SHA1 over sequence, type, version, length and plain, under RC4.
    #[test]
    fn an_rc4_record_is_what_tls_says() {
        let plain = b"packet";
        let mut sealed = vec![];
        Cipher::new(&[7; 16], &[9; 20], true).seal(23, 0x0302, plain, &mut sealed);
        let covered = [&0u64.to_be_bytes()[..], &[23, 3, 2], &be16(plain.len()), plain].concat();
        let mut expected = [&plain[..], &hmac::<Sha1>(&[9; 20], &covered)].concat();
        Rc4::new(&[7; 16]).apply(&mut expected);
        assert_eq!(sealed, expected);
    }
}
