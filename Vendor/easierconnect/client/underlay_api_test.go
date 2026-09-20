package client_test

import (
	"context"
	"net"
	"testing"

	"termther/easyconnect/client"
	"termther/easyconnect/client/easyconnect"
	"termther/easyconnect/underlay"
)

type externalUnderlay struct{}

func (externalUnderlay) DialContext(context.Context, string, string) (net.Conn, error) {
	return nil, nil
}

func (externalUnderlay) ExcludeIP(net.IP) {}

var (
	_ client.UnderlayDialer = externalUnderlay{}
	_ client.UnderlayDialer = (*underlay.Dialer)(nil)
)

func TestEasyConnectAcceptsExternalUnderlay(t *testing.T) {
	var dialer client.UnderlayDialer = externalUnderlay{}

	easyClient := easyconnect.NewClient(easyconnect.Options{
		Server:         "vpn.example.com:443",
		UnderlayDialer: dialer,
	})
	if easyClient == nil {
		t.Fatal("easyconnect.NewClient returned nil")
	}
	easyClient.Close()
}
