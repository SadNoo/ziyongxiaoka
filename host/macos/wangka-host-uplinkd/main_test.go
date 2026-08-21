package main

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type recordedCommand struct {
	input string
	name  string
	args  []string
}

type fakeRunner struct {
	commands []recordedCommand
}

func (runner *fakeRunner) Run(input string, name string, args ...string) (string, error) {
	runner.commands = append(runner.commands, recordedCommand{input: input, name: name, args: args})
	joined := name + " " + strings.Join(args, " ")
	switch {
	case strings.Contains(joined, "/sbin/route -n get default"):
		return "interface: en0\n", nil
	case strings.Contains(joined, "sysctl -n net.inet.ip.forwarding"):
		return "0\n", nil
	case strings.Contains(joined, "pfctl -E"):
		return "pf enabled\nToken : 42\n", nil
	case strings.Contains(joined, "scutil --dns"):
		return "nameserver[0] : 10.0.0.53\n", nil
	default:
		return "", nil
	}
}

func TestParseDefaultInterface(t *testing.T) {
	got, err := parseDefaultInterface("   route to: default\n  interface: utun10\n")
	if err != nil || got != "utun10" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := parseDefaultInterface("interface: ../../bad\n"); err == nil {
		t.Fatal("invalid interface was accepted")
	}
}

func TestParseDNSServers(t *testing.T) {
	input := strings.Join([]string{
		"nameserver[0] : 192.168.5.1",
		"nameserver[1] : 10.0.0.53",
		"nameserver[2] : 10.0.0.53",
		"nameserver[3] : 2001:4860:4860::8888",
		"nameserver[4] : 1.1.1.1",
	}, "\n")
	got := parseDNSServers(input)
	if len(got) != 2 || got[0] != "10.0.0.53" || got[1] != "1.1.1.1" {
		t.Fatalf("unexpected DNS list: %#v", got)
	}
	if fallback := parseDNSServers(""); len(fallback) != 2 || fallback[0] != "114.114.114.114" || fallback[1] != "223.5.5.5" {
		t.Fatalf("unexpected fallback: %#v", fallback)
	}
}

func TestParsePFToken(t *testing.T) {
	got, err := parsePFToken("pf enabled\nToken : 123456789\n")
	if err != nil || got != "123456789" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := parsePFToken("Token : not-a-token"); err == nil {
		t.Fatal("invalid token accepted")
	}
}

func TestSecretValidation(t *testing.T) {
	if !tokenPattern.MatchString(strings.Repeat("a", 64)) {
		t.Fatal("valid token rejected")
	}
	if tokenPattern.MatchString(strings.Repeat("A", 64)) || tokenPattern.MatchString("short") {
		t.Fatal("invalid token accepted")
	}
}

func TestEnableUsesPrivateAnchorAndDeviceOnlySource(t *testing.T) {
	runner := &fakeRunner{}
	now := time.Unix(1_787_328_000, 0)
	helper := &helper{
		runner:       runner,
		statePath:    filepath.Join(t.TempDir(), "state.json"),
		secret:       strings.Repeat("a", 64),
		usbInterface: "en11",
		usbHostIP:    "192.168.5.242",
		now:          func() time.Time { return now },
	}
	response, err := helper.enableLocked()
	if err != nil {
		t.Fatal(err)
	}
	if !response.Enabled || response.UpstreamInterface != "en0" {
		t.Fatalf("unexpected response: %#v", response)
	}
	var rules string
	for _, command := range runner.commands {
		if command.name == "/sbin/pfctl" && len(command.args) >= 4 && command.args[0] == "-a" {
			rules = command.input
		}
	}
	if !strings.Contains(rules, "from 192.168.5.1/32") || strings.Contains(rules, "192.168.5.0/24") {
		t.Fatalf("NAT source is not device-only: %q", rules)
	}
	helper.disableLocked()
	joined := ""
	for _, command := range runner.commands {
		joined += command.name + " " + strings.Join(command.args, " ") + "\n"
	}
	if !strings.Contains(joined, "pfctl -a "+anchorName+" -F all") {
		t.Fatalf("private anchor was not cleared:\n%s", joined)
	}
	if !strings.Contains(joined, "pfctl -X 42") || !strings.Contains(joined, "sysctl -w net.inet.ip.forwarding=0") {
		t.Fatalf("PF reference or forwarding state was not restored:\n%s", joined)
	}
}

func TestStatusUsesCachedDNSWithoutRunningSystemCommands(t *testing.T) {
	runner := &fakeRunner{}
	helper := &helper{
		runner:       runner,
		statePath:    filepath.Join(t.TempDir(), "state.json"),
		secret:       strings.Repeat("a", 64),
		usbInterface: "en11",
		usbHostIP:    "192.168.5.242",
		now:          func() time.Time { return time.Unix(1_787_328_000, 0) },
	}
	if _, err := helper.enableLocked(); err != nil {
		t.Fatal(err)
	}
	commandCount := len(runner.commands)
	response := helper.statusLocked()
	if len(runner.commands) != commandCount {
		t.Fatalf("status executed a system command: before=%d after=%d", commandCount, len(runner.commands))
	}
	if len(response.DNSServers) != 1 || response.DNSServers[0] != "10.0.0.53" {
		t.Fatalf("status did not return cached DNS: %#v", response.DNSServers)
	}
}
