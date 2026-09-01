module termther/ecshim

go 1.25.6

require termther/easyconnect v1.3.1

require (
	github.com/andybalholm/brotli v1.2.1 // indirect
	github.com/beevik/etree v1.6.0 // indirect
	github.com/boombuler/barcode v1.1.0 // indirect
	github.com/ebitengine/purego v0.10.0 // indirect
	github.com/fsnotify/fsnotify v1.10.1 // indirect
	github.com/go-ole/go-ole v1.3.0 // indirect
	github.com/google/btree v1.1.3 // indirect
	github.com/klauspost/compress v1.18.6 // indirect
	github.com/metacubex/gvisor v0.0.0-20251227095601-261ec1326fe8 // indirect
	github.com/miekg/dns v1.1.72 // indirect
	github.com/mythologyli/sing-tun v0.0.0-20260201144630-c04d9db95dc7 // indirect
	github.com/patrickmn/go-cache v2.1.0+incompatible // indirect
	github.com/power-devops/perfstat v0.0.0-20240221224432-82ca36839d55 // indirect
	github.com/pquerna/otp v1.5.0 // indirect
	github.com/refraction-networking/utls v1.8.2 // indirect
	github.com/sagernet/go-tun2socks v1.16.12-0.20220818015926-16cb67876a61 // indirect
	github.com/sagernet/netlink v0.0.0-20240916134442-83396419aa8b // indirect
	github.com/sagernet/sing v0.7.18 // indirect
	github.com/scjalliance/comshim v0.0.0-20251021001035-b69f3cdad6f3 // indirect
	github.com/shirou/gopsutil/v4 v4.26.4 // indirect
	github.com/vishvananda/netns v0.0.5 // indirect
	github.com/yusufpapurcu/wmi v1.2.4 // indirect
	go4.org/intern v0.0.0-20230525184215-6c62f75575cb // indirect
	go4.org/unsafe/assume-no-moving-gc v0.0.0-20231121144256-b99613f794b6 // indirect
	golang.org/x/crypto v0.52.0 // indirect
	golang.org/x/exp v0.0.0-20260508232706-74f9aab9d74a // indirect
	golang.org/x/mod v0.36.0 // indirect
	golang.org/x/net v0.55.0 // indirect
	golang.org/x/sync v0.20.0 // indirect
	golang.org/x/sys v0.45.0 // indirect
	golang.org/x/time v0.15.0 // indirect
	golang.org/x/tools v0.45.0 // indirect
	gvisor.dev/gvisor v0.0.0-20260129214308-cb856800aa1c // indirect
	inet.af/netaddr v0.0.0-20230525184311-b8eac61e914a // indirect
)

// A local fork, patched so a broken tunnel cannot end the process. See
// ../easierconnect/stack/gvisor/stack.go -- every change is marked TERMTHER
// PATCH. Same licence (AGPL-3.0); the modifications stay in the tree.
//
// Where the fork came from, and what was changed to it, is stated in
// ../easierconnect/NOTICE. That file is the attribution the licence requires;
// it stays.
replace termther/easyconnect => ../easierconnect
