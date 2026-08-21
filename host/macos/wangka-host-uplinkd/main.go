// wangka-host-uplinkd provides a deliberately small macOS NAT helper for one
// directly attached Wangka Debian device. It never accepts shell commands or
// caller supplied network interfaces.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	anchorName  = "com.apple/wangka-host-uplink"
	deviceCIDR  = "192.168.5.1/32"
	deviceIP    = "192.168.5.1"
	leaseLength = 90 * time.Second
)

var (
	interfacePattern = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9]{0,15}$`)
	tokenPattern     = regexp.MustCompile(`^[a-f0-9]{64}$`)
	pfTokenPattern   = regexp.MustCompile(`(?m)Token\s*:\s*([0-9]+)\s*$`)
)

type commandRunner interface {
	Run(input string, name string, args ...string) (string, error)
}

type realRunner struct{}

func (realRunner) Run(input string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	if input != "" {
		cmd.Stdin = strings.NewReader(input)
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		return string(output), fmt.Errorf("%s failed: %w", filepath.Base(name), err)
	}
	return string(output), nil
}

type persistedState struct {
	Enabled            bool     `json:"enabled"`
	USBInterface       string   `json:"usb_interface,omitempty"`
	UpstreamInterface  string   `json:"upstream_interface,omitempty"`
	ForwardingWas      int      `json:"forwarding_was"`
	PFToken            string   `json:"pf_token,omitempty"`
	DNSServers         []string `json:"dns_servers,omitempty"`
	LeaseDeadlineEpoch int64    `json:"lease_deadline_epoch,omitempty"`
	UpdatedAtEpoch     int64    `json:"updated_at_epoch"`
	LastError          string   `json:"last_error,omitempty"`
}

type helper struct {
	mu           sync.Mutex
	runner       commandRunner
	statePath    string
	secret       string
	usbInterface string
	usbHostIP    string
	state        persistedState
	now          func() time.Time
}

type statusResponse struct {
	Status             string   `json:"status"`
	Enabled            bool     `json:"enabled"`
	USBInterface       string   `json:"usb_interface"`
	HostAddress        string   `json:"host_address"`
	UpstreamInterface  string   `json:"upstream_interface,omitempty"`
	DNSServers         []string `json:"dns_servers,omitempty"`
	LeaseDeadlineEpoch int64    `json:"lease_deadline_epoch,omitempty"`
	LastError          string   `json:"last_error,omitempty"`
}

func readSecret(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	secret := strings.TrimSpace(string(raw))
	if !tokenPattern.MatchString(secret) {
		return "", errors.New("token must be exactly 64 lowercase hexadecimal characters")
	}
	return secret, nil
}

func loadState(path string) persistedState {
	var state persistedState
	raw, err := os.ReadFile(path)
	if err == nil {
		_ = json.Unmarshal(raw, &state)
	}
	return state
}

func saveState(path string, state persistedState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	temporary := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	if err := os.WriteFile(temporary, raw, 0600); err != nil {
		return err
	}
	if err := os.Chmod(temporary, 0600); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func parseDefaultInterface(output string) (string, error) {
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "interface:" {
			if !interfacePattern.MatchString(fields[1]) {
				return "", errors.New("default route returned an invalid interface")
			}
			return fields[1], nil
		}
	}
	return "", errors.New("no default route interface found")
}

func parseForwarding(output string) (int, error) {
	value := strings.TrimSpace(output)
	if value == "0" {
		return 0, nil
	}
	if value == "1" {
		return 1, nil
	}
	return 0, fmt.Errorf("unexpected forwarding value %q", value)
}

func parsePFToken(output string) (string, error) {
	match := pfTokenPattern.FindStringSubmatch(output)
	if len(match) == 2 {
		return match[1], nil
	}
	return "", errors.New("pfctl did not return a reference token")
}

func parseDNSServers(output string) []string {
	seen := make(map[string]bool)
	servers := make([]string, 0, 3)
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 || !strings.HasPrefix(fields[0], "nameserver[") || fields[1] != ":" {
			continue
		}
		address := net.ParseIP(fields[2])
		if address == nil || address.To4() == nil {
			continue
		}
		value := address.String()
		if value == "127.0.0.1" || value == "0.0.0.0" || strings.HasPrefix(value, "169.254.") || strings.HasPrefix(value, "192.168.5.") || seen[value] {
			continue
		}
		seen[value] = true
		servers = append(servers, value)
		if len(servers) == 3 {
			break
		}
	}
	if len(servers) == 0 {
		return []string{"114.114.114.114", "223.5.5.5"}
	}
	return servers
}

func (h *helper) detectUpstream() (string, error) {
	output, err := h.runner.Run("", "/sbin/route", "-n", "get", "default")
	if err != nil {
		return "", err
	}
	upstream, err := parseDefaultInterface(output)
	if err != nil {
		return "", err
	}
	if upstream == h.usbInterface || upstream == "lo0" {
		return "", errors.New("USB management interface cannot be the upstream")
	}
	return upstream, nil
}

func (h *helper) dnsServers() []string {
	output, err := h.runner.Run("", "/usr/sbin/scutil", "--dns")
	if err != nil {
		return []string{"114.114.114.114", "223.5.5.5"}
	}
	return parseDNSServers(output)
}

func (h *helper) loadAnchor(upstream string) error {
	rules := fmt.Sprintf("nat on %s inet from %s to any -> (%s)\npass quick on %s inet from %s to any keep state\npass out quick on %s inet from %s to any keep state\n", upstream, deviceCIDR, upstream, h.usbInterface, deviceCIDR, upstream, deviceCIDR)
	_, err := h.runner.Run(rules, "/sbin/pfctl", "-a", anchorName, "-f", "-")
	return err
}

func (h *helper) clearAnchor() {
	_, _ = h.runner.Run("", "/sbin/pfctl", "-a", anchorName, "-F", "all")
}

func (h *helper) enableLocked() (statusResponse, error) {
	upstream, err := h.detectUpstream()
	if err != nil {
		return statusResponse{}, err
	}

	if h.state.Enabled {
		dnsServers := h.dnsServers()
		if err := h.loadAnchor(upstream); err != nil {
			return statusResponse{}, err
		}
		h.state.UpstreamInterface = upstream
		h.state.DNSServers = dnsServers
		h.state.LeaseDeadlineEpoch = h.now().Add(leaseLength).Unix()
		h.state.UpdatedAtEpoch = h.now().Unix()
		h.state.LastError = ""
		if err := saveState(h.statePath, h.state); err != nil {
			return statusResponse{}, err
		}
		return h.statusLocked(), nil
	}

	forwardingOutput, err := h.runner.Run("", "/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding")
	if err != nil {
		return statusResponse{}, err
	}
	forwardingWas, err := parseForwarding(forwardingOutput)
	if err != nil {
		return statusResponse{}, err
	}
	if forwardingWas == 0 {
		if _, err := h.runner.Run("", "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"); err != nil {
			return statusResponse{}, err
		}
	}
	pfOutput, err := h.runner.Run("", "/sbin/pfctl", "-E")
	if err != nil {
		if forwardingWas == 0 {
			_, _ = h.runner.Run("", "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0")
		}
		return statusResponse{}, err
	}
	pfToken, err := parsePFToken(pfOutput)
	if err != nil {
		if forwardingWas == 0 {
			_, _ = h.runner.Run("", "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0")
		}
		return statusResponse{}, err
	}
	if err := h.loadAnchor(upstream); err != nil {
		h.clearAnchor()
		_, _ = h.runner.Run("", "/sbin/pfctl", "-X", pfToken)
		if forwardingWas == 0 {
			_, _ = h.runner.Run("", "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0")
		}
		return statusResponse{}, err
	}

	h.state = persistedState{
		Enabled:            true,
		USBInterface:       h.usbInterface,
		UpstreamInterface:  upstream,
		ForwardingWas:      forwardingWas,
		PFToken:            pfToken,
		DNSServers:         h.dnsServers(),
		LeaseDeadlineEpoch: h.now().Add(leaseLength).Unix(),
		UpdatedAtEpoch:     h.now().Unix(),
	}
	if err := saveState(h.statePath, h.state); err != nil {
		h.disableLocked()
		return statusResponse{}, err
	}
	return h.statusLocked(), nil
}

func (h *helper) disableLocked() statusResponse {
	previous := h.state
	h.clearAnchor()
	wasManaged := previous.Enabled || previous.PFToken != ""
	if previous.PFToken != "" {
		_, _ = h.runner.Run("", "/sbin/pfctl", "-X", previous.PFToken)
	}
	if wasManaged && previous.ForwardingWas == 0 {
		_, _ = h.runner.Run("", "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0")
	}
	h.state = persistedState{UpdatedAtEpoch: h.now().Unix()}
	if err := saveState(h.statePath, h.state); err != nil {
		h.state.LastError = "cannot persist disabled state"
	}
	return h.statusLocked()
}

func (h *helper) statusLocked() statusResponse {
	response := statusResponse{
		Status:             "ok",
		Enabled:            h.state.Enabled,
		USBInterface:       h.usbInterface,
		HostAddress:        h.usbHostIP,
		UpstreamInterface:  h.state.UpstreamInterface,
		LeaseDeadlineEpoch: h.state.LeaseDeadlineEpoch,
		LastError:          h.state.LastError,
	}
	if h.state.Enabled {
		response.DNSServers = append([]string(nil), h.state.DNSServers...)
	}
	return response
}

func (h *helper) recoverStaleState() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.state.Enabled || h.state.PFToken != "" {
		log.Printf("recovering stale NAT state before accepting requests")
		h.disableLocked()
	}
}

func (h *helper) leaseLoop() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		h.mu.Lock()
		if h.state.Enabled && h.state.LeaseDeadlineEpoch <= h.now().Unix() {
			log.Printf("host-uplink lease expired; removing NAT state")
			h.disableLocked()
		}
		h.mu.Unlock()
	}
}

func (h *helper) authorized(request *http.Request) bool {
	host, _, err := net.SplitHostPort(request.RemoteAddr)
	if err != nil {
		return false
	}
	if host != deviceIP && host != h.usbHostIP && host != "127.0.0.1" {
		return false
	}
	provided := request.Header.Get("X-Wangka-Token")
	return len(provided) == len(h.secret) && subtle.ConstantTimeCompare([]byte(provided), []byte(h.secret)) == 1
}

func writeJSON(writer http.ResponseWriter, code int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(code)
	_ = json.NewEncoder(writer).Encode(value)
}

func (h *helper) serveHTTP(writer http.ResponseWriter, request *http.Request) {
	if !h.authorized(request) {
		writeJSON(writer, http.StatusForbidden, map[string]string{"status": "error", "message": "forbidden"})
		return
	}
	if request.ContentLength > 1024 {
		writeJSON(writer, http.StatusRequestEntityTooLarge, map[string]string{"status": "error", "message": "request too large"})
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(request.Body, 1025))

	h.mu.Lock()
	defer h.mu.Unlock()
	switch {
	case request.Method == http.MethodGet && request.URL.Path == "/v1/status":
		writeJSON(writer, http.StatusOK, h.statusLocked())
	case request.Method == http.MethodPost && request.URL.Path == "/v1/enable":
		response, err := h.enableLocked()
		if err != nil {
			h.state.LastError = err.Error()
			_ = saveState(h.statePath, h.state)
			writeJSON(writer, http.StatusInternalServerError, map[string]string{"status": "error", "message": "cannot enable host uplink"})
			return
		}
		writeJSON(writer, http.StatusOK, response)
	case request.Method == http.MethodPost && request.URL.Path == "/v1/disable":
		writeJSON(writer, http.StatusOK, h.disableLocked())
	default:
		writeJSON(writer, http.StatusNotFound, map[string]string{"status": "error", "message": "not found"})
	}
}

func main() {
	listen := flag.String("listen", "192.168.5.242:19531", "USB-only listen address")
	usbInterface := flag.String("usb-interface", "en11", "USB ECM interface")
	secretPath := flag.String("secret", "/Library/Application Support/Wangka/host-uplink.token", "pairing token path")
	statePath := flag.String("state", "/var/db/wangka-host-uplink/state.json", "persistent state path")
	flag.Parse()

	if os.Geteuid() != 0 {
		log.Fatal("wangka-host-uplinkd must run as root")
	}
	if !interfacePattern.MatchString(*usbInterface) {
		log.Fatal("invalid USB interface")
	}
	host, _, err := net.SplitHostPort(*listen)
	if err != nil || net.ParseIP(host) == nil || host != "192.168.5.242" {
		log.Fatal("listen address must be 192.168.5.242 with an explicit port")
	}
	secret, err := readSecret(*secretPath)
	if err != nil {
		log.Fatalf("cannot read pairing token: %v", err)
	}

	h := &helper{
		runner:       realRunner{},
		statePath:    *statePath,
		secret:       secret,
		usbInterface: *usbInterface,
		usbHostIP:    host,
		state:        loadState(*statePath),
		now:          time.Now,
	}
	h.recoverStaleState()
	go h.leaseLoop()

	server := &http.Server{
		Addr:              *listen,
		Handler:           http.HandlerFunc(h.serveHTTP),
		ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       15 * time.Second,
		MaxHeaderBytes:    8 * 1024,
	}
	log.Printf("listening on %s for device %s via %s", *listen, deviceIP, *usbInterface)
	log.Fatal(server.ListenAndServe())
}
