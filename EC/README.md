# termther-ec

Termther's EasyConnect engine. The macOS app links it as a static library
(`Vendor/build-ec.sh`, C ABI in `include/termther_ec.h`); on Linux the same
crate is `termther-ec`, which serves the tunnel as a SOCKS5 proxy on loopback.
No TUN device, no root, no routing change.

```sh
cargo build --release
TERMTHER_EC_PASSWORD=... target/release/termther-ec vpn.example.edu.cn:443 you
ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:1080 %h %p' user@10.1.2.3   # OpenBSD nc
```

Names given to the proxy are resolved with the gateway's DNS servers, so
split-horizon names work. Everything sent to the proxy goes through the tunnel;
traffic to hosts outside the gateway's route list is dropped by the gateway.

`--interface` uses `SO_BINDTODEVICE` on Linux, which needs `CAP_NET_RAW` on
older kernels (`sudo setcap cap_net_raw+ep target/release/termther-ec`).

```sh
cargo test                        # everything that needs no network
TERMTHER_TLS_SERVER=127.0.0.1:4433 cargo test live_tls   # see tls.rs
TERMTHER_EC_GATEWAY=host:443 TERMTHER_EC_USER=you TERMTHER_EC_PASSWORD=... cargo test live_login
```
