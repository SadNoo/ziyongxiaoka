package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestQADBPublishedVectors(t *testing.T) {
	vectors := map[string]string{
		"12345678": "0jXKXQwSwMxYoeg",
		"15478726": "n9Qq0s1x4LtgAvt",
		"31711264": "SV3LHz1ynUZZmYU",
	}
	for challenge, expected := range vectors {
		actual, err := qadbPassword(challenge)
		if err != nil || actual != expected {
			t.Fatalf("qadbPassword(%q)=%q err=%v, want %q", challenge, actual, err, expected)
		}
	}
}

func TestQADBChallengeParserRejectsAmbiguousInput(t *testing.T) {
	challenge, err := parseQADBChallenge("AT+QADBKEY?\r\n+QADBKEY: 12345678\r\nOK\r\n")
	if err != nil || challenge != "12345678" {
		t.Fatalf("challenge=%q err=%v", challenge, err)
	}
	for _, response := range []string{
		"+QADBKEY: 12345678",
		"+QADBKEY: P1KR27_13\r\nOK",
		"+QADBKEY: 12345678\r\n+QADBKEY: 87654321\r\nOK",
	} {
		if _, err := parseQADBChallenge(response); err == nil {
			t.Fatalf("accepted invalid response %q", response)
		}
	}
}

func TestADBAndUACTargetPreservesIdentityAndOtherFlags(t *testing.T) {
	original := usbComposition{VendorID: 0x2ca3, ProductID: 0x4006, Flags: []int{1, 0, 1, 1, 1, 0, 0}}
	target, err := original.adbUACTarget()
	if err != nil {
		t.Fatal(err)
	}
	if target.VendorID != original.VendorID || target.ProductID != original.ProductID {
		t.Fatal("USB identity changed")
	}
	if !reflect.DeepEqual(target.Flags, []int{1, 0, 1, 1, 1, 1, 1}) {
		t.Fatalf("flags=%v", target.Flags)
	}
	if strings.Contains(target.command(), "2C7C") || !strings.Contains(target.command(), "0x2CA3,0x4006") {
		t.Fatalf("unsafe target command %q", target.command())
	}
}

func TestPrivateBackupRoundTripAndInitializationState(t *testing.T) {
	directory := filepath.Join(t.TempDir(), backupDirectoryName)
	identity := moduleIdentity{IMEI: "000000000000000", Firmware: "TEST"}
	usb := usbComposition{VendorID: 0x2ca3, ProductID: 0x4006, Flags: []int{1, 1, 1, 1, 1, 0, 0}}
	voice := voiceConfiguration{IMS: 0, VoLTECapability: 0, VoLTEDisabled: 0}
	backup, err := writeBackup(directory, preInitialize, identity, usb, voice)
	if err != nil {
		t.Fatal(err)
	}
	if backup.Module.IMEI != identity.IMEI {
		t.Fatal("backup identity changed")
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries=%d err=%v", len(entries), err)
	}
	info, err := entries[0].Info()
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("backup permissions=%o", info.Mode().Perm())
	}
	state := inspectInitialization(directory, identity.IMEI, &usb, false, false)
	if !state.BackupAvailable || state.BackupCount != 1 || !state.CanInitialize || state.CanRestore {
		t.Fatalf("state=%+v", state)
	}
}

func TestBackupDirectoryNameIsConstrained(t *testing.T) {
	if _, err := secureBackupDirectory(t.TempDir(), true); err == nil {
		t.Fatal("accepted an unconstrained backup directory")
	}
}

type scriptedModem struct {
	responses map[string]string
}

func (modem scriptedModem) Command(command string, _ time.Duration) (string, error) {
	return modem.responses[command], nil
}

func (scriptedModem) USBID() string { return "test" }
func (scriptedModem) Close()        {}

func TestVoiceConfigurationReadsCapabilitySeparately(t *testing.T) {
	modem := scriptedModem{responses: map[string]string{
		`AT+QCFG="ims"`:           "+QCFG: \"ims\",0,0\r\nOK\r\n",
		`AT+QCFG="volte_disable"`: "+QCFG: \"volte/disable\",0\r\nOK\r\n",
	}}
	voice, err := readVoiceConfiguration(modem)
	if err != nil {
		t.Fatal(err)
	}
	if voice.IMS != 0 || voice.VoLTECapability != 0 || voice.VoLTEDisabled != 0 {
		t.Fatalf("voice=%+v", voice)
	}
}

func TestVoiceCapabilityGateRejectsUnsupportedAndUnknownModules(t *testing.T) {
	unsupported := scriptedModem{responses: map[string]string{
		`AT+QCFG="ims"`:           "+QCFG: \"ims\",0,0\r\nOK\r\n",
		`AT+QCFG="volte_disable"`: "+QCFG: \"volte/disable\",0\r\nOK\r\n",
	}}
	if err := requireVoiceCapability(unsupported); err == nil || !strings.Contains(err.Error(), "capability=0") {
		t.Fatalf("unsupported gate error=%v", err)
	}

	unknown := scriptedModem{responses: map[string]string{}}
	if err := requireVoiceCapability(unknown); err == nil || !strings.Contains(err.Error(), "无法确认") {
		t.Fatalf("unknown gate error=%v", err)
	}

	supported := scriptedModem{responses: map[string]string{
		`AT+QCFG="ims"`:           "+QCFG: \"ims\",1,1\r\nOK\r\n",
		`AT+QCFG="volte_disable"`: "+QCFG: \"volte/disable\",0\r\nOK\r\n",
	}}
	if err := requireVoiceCapability(supported); err != nil {
		t.Fatalf("supported gate error=%v", err)
	}
}

func TestVoiceCallDetectionIgnoresDataBearer(t *testing.T) {
	dataOnly := scriptedModem{responses: map[string]string{
		"AT+CLCC": "+CLCC: 1,0,0,1,0\r\nOK\r\n",
	}}
	if hasVoiceCall(dataOnly) {
		t.Fatal("data bearer was treated as a voice call")
	}
	voice := scriptedModem{responses: map[string]string{
		"AT+CLCC": "+CLCC: 1,0,0,0,0\r\nOK\r\n",
	}}
	if !hasVoiceCall(voice) {
		t.Fatal("voice call was not detected")
	}
}
