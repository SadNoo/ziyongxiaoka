package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const bridgeVersion = "0.2.0"

type snapshot struct {
	Status         string             `json:"status"`
	Version        string             `json:"version"`
	Device         deviceInfo         `json:"device"`
	SIM            simInfo            `json:"sim"`
	Network        networkInfo        `json:"network"`
	Voice          voiceInfo          `json:"voice"`
	Initialization initializationInfo `json:"initialization"`
	Call           callInfo           `json:"call"`
	Error          string             `json:"error,omitempty"`
}

type deviceInfo struct {
	ID         string `json:"id"`
	Family     string `json:"family"`
	Vendor     string `json:"vendor"`
	Model      string `json:"model"`
	Firmware   string `json:"firmware"`
	USBID      string `json:"usb_id"`
	IMEISuffix string `json:"imei_suffix,omitempty"`
}

type simInfo struct {
	State string `json:"state"`
	ICCID string `json:"iccid,omitempty"`
}

type networkInfo struct {
	Registration string `json:"registration"`
	SignalDBM    *int   `json:"signal_dbm,omitempty"`
}

type voiceInfo struct {
	HardwareSupported bool   `json:"hardware_supported"`
	ControlAvailable  bool   `json:"control_available"`
	ADBEnabled        bool   `json:"adb_enabled"`
	UACEnabled        bool   `json:"uac_enabled"`
	IMSEnabled        bool   `json:"ims_enabled"`
	VoLTECapability   int    `json:"volte_capability"`
	VoLTEEnabled      bool   `json:"volte_enabled"`
	Availability      string `json:"availability"`
	Reason            string `json:"reason"`
}

type callInfo struct {
	State    string `json:"state"`
	Number   string `json:"number,omitempty"`
	Incoming bool   `json:"incoming"`
	Active   bool   `json:"active"`
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "initialize-usb" || os.Args[1] == "restore-usb") {
		result, err := runDeviceOperation(os.Args[1:])
		if err != nil {
			result.Status = "error"
			result.Error = err.Error()
		}
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetEscapeHTML(false)
		if encodeErr := encoder.Encode(result); encodeErr != nil {
			fmt.Fprintf(os.Stderr, "encode operation result: %v\n", encodeErr)
			os.Exit(1)
		}
		if err != nil {
			os.Exit(2)
		}
		return
	}
	result := run(os.Args[1:])
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "encode result: %v\n", err)
		os.Exit(1)
	}
	if result.Status != "ok" {
		os.Exit(2)
	}
}

func run(args []string) snapshot {
	if len(args) == 0 {
		return failure(errors.New("缺少命令；支持 probe、status、dial、answer、hangup、initialize-usb、restore-usb"))
	}
	if args[0] == "status" && len(args) > 2 {
		return failure(errors.New("status 最多接受一个备份目录参数"))
	}
	if args[0] != "status" && args[0] != "dial" && len(args) != 1 {
		return failure(fmt.Errorf("%s 参数无效", args[0]))
	}
	modem, err := openUSBModem()
	if err != nil {
		return failure(err)
	}
	defer modem.Close()

	switch args[0] {
	case "probe":
		return collectSnapshot(modem, "")
	case "status":
		backupDirectory := ""
		if len(args) == 2 {
			backupDirectory = args[1]
		}
		result := collectSnapshot(modem, backupDirectory)
		result.Call = readCall(modem)
		return result
	case "dial":
		if len(args) != 2 {
			return failure(errors.New("dial 需要一个电话号码"))
		}
		if err := requireVoiceCapability(modem); err != nil {
			return failure(err)
		}
		number, valid := normalizePhone(args[1])
		if !valid {
			return failure(errors.New("电话号码只允许 + 和数字，长度应为 3 到 20 位"))
		}
		response, commandErr := modem.Command("ATD"+number+";", 5*time.Second)
		if commandErr != nil || !atSucceeded(response) {
			return failure(commandFailure("拨号", response, commandErr))
		}
		time.Sleep(250 * time.Millisecond)
		result := collectSnapshot(modem, "")
		result.Call = readCall(modem)
		return result
	case "answer":
		if err := requireVoiceCapability(modem); err != nil {
			return failure(err)
		}
		response, commandErr := modem.Command("ATA", 5*time.Second)
		if commandErr != nil || !atSucceeded(response) {
			return failure(commandFailure("接听", response, commandErr))
		}
		time.Sleep(250 * time.Millisecond)
		result := collectSnapshot(modem, "")
		result.Call = readCall(modem)
		return result
	case "hangup":
		response, commandErr := modem.Command("ATH", 5*time.Second)
		if commandErr != nil || !atSucceeded(response) {
			return failure(commandFailure("挂断", response, commandErr))
		}
		time.Sleep(250 * time.Millisecond)
		result := collectSnapshot(modem, "")
		result.Call = readCall(modem)
		return result
	default:
		return failure(fmt.Errorf("未知命令 %q", args[0]))
	}
}

func requireVoiceCapability(modem usbModem) error {
	configuration, err := readVoiceConfiguration(modem)
	if err != nil {
		return fmt.Errorf("无法确认 VoLTE 能力，已禁用通话：%w", err)
	}
	if configuration.VoLTECapability != 1 {
		return errors.New("模块报告 VoLTE capability=0，WiSiM 已禁用通话")
	}
	return nil
}

func failure(err error) snapshot {
	return snapshot{
		Status:         "error",
		Version:        bridgeVersion,
		Device:         deviceInfo{ID: "dji-qdc507", Family: "dji-qdc507", Vendor: "BAIWANG", Model: "QDC507"},
		Voice:          voiceInfo{HardwareSupported: true, VoLTECapability: -1, Availability: "unavailable", Reason: err.Error()},
		Initialization: initializationInfo{State: "unavailable", Reason: err.Error()},
		Call:           callInfo{State: "unknown"},
		Error:          err.Error(),
	}
}

func collectSnapshot(modem usbModem, backupDirectory string) snapshot {
	result := snapshot{
		Status:  "ok",
		Version: bridgeVersion,
		Device:  deviceInfo{ID: "dji-qdc507", Family: "dji-qdc507", Vendor: "BAIWANG", Model: "QDC507", USBID: modem.USBID()},
		SIM:     simInfo{State: "unknown"},
		Network: networkInfo{Registration: "unknown"},
		Voice: voiceInfo{
			HardwareSupported: true,
			ControlAvailable:  true,
			VoLTECapability:   -1,
			Availability:      "needs_setup",
			Reason:            "正在核对通话所需配置",
		},
		Call: callInfo{State: "idle"},
	}

	if response, err := modem.Command("ATI", 2500*time.Millisecond); err == nil {
		for _, line := range responseLines(response) {
			upper := strings.ToUpper(line)
			if strings.HasPrefix(upper, "REVISION:") {
				result.Device.Firmware = strings.TrimSpace(strings.TrimPrefix(line, "Revision:"))
			}
		}
	}
	imei := ""
	if response, err := modem.Command("AT+CGSN", 2500*time.Millisecond); err == nil {
		imei = firstCapture(response, `(?m)^\s*([0-9]{15})\s*$`)
		if len(imei) == 15 {
			result.Device.IMEISuffix = imei[len(imei)-4:]
		}
	}

	if response, err := modem.Command("AT+CPIN?", 2500*time.Millisecond); err == nil {
		upper := strings.ToUpper(response)
		switch {
		case strings.Contains(upper, "+CPIN: READY"):
			result.SIM.State = "ready"
		case strings.Contains(upper, "CME ERROR: 10"):
			result.SIM.State = "absent"
		case strings.Contains(upper, "+CPIN: SIM PIN"):
			result.SIM.State = "pin_required"
		default:
			result.SIM.State = "unavailable"
		}
	}
	if result.SIM.State == "ready" {
		if response, err := modem.Command("AT+QCCID", 2500*time.Millisecond); err == nil {
			result.SIM.ICCID = firstCapture(response, `(?m)\+QCCID:\s*([0-9]+)`)
		}
	}

	if response, err := modem.Command("AT+CEREG?", 2500*time.Millisecond); err == nil {
		registration := firstCapture(response, `(?m)\+CEREG:\s*\d+\s*,\s*(\d+)`)
		switch registration {
		case "1":
			result.Network.Registration = "registered"
		case "5":
			result.Network.Registration = "roaming"
		case "2":
			result.Network.Registration = "searching"
		case "3":
			result.Network.Registration = "denied"
		case "0":
			result.Network.Registration = "not_registered"
		}
	}
	if response, err := modem.Command("AT+CSQ", 2500*time.Millisecond); err == nil {
		if raw := firstCapture(response, `(?m)\+CSQ:\s*(\d+)`); raw != "" {
			if value, convertErr := strconv.Atoi(raw); convertErr == nil && value >= 0 && value <= 31 {
				dbm := -113 + (2 * value)
				result.Network.SignalDBM = &dbm
			}
		}
	}

	var currentUSB *usbComposition
	if response, err := modem.Command(`AT+QCFG="usbcfg"?`, 2500*time.Millisecond); err == nil {
		if composition, parseErr := parseUSBComposition(response); parseErr == nil {
			currentUSB = &composition
			result.Voice.ADBEnabled = composition.Flags[5] == 1
			result.Voice.UACEnabled = composition.Flags[6] == 1
		}
	}
	voiceConfiguration, voiceErr := readVoiceConfiguration(modem)
	if voiceErr == nil {
		result.Voice.IMSEnabled = voiceConfiguration.IMS == 1
		result.Voice.VoLTECapability = voiceConfiguration.VoLTECapability
		result.Voice.VoLTEEnabled = voiceConfiguration.VoLTEDisabled == 0
	}
	result.Initialization = inspectInitialization(
		backupDirectory,
		imei,
		currentUSB,
		result.Voice.ADBEnabled,
		result.Voice.UACEnabled,
	)
	if voiceErr != nil {
		result.Voice.Availability = "unavailable"
		result.Voice.Reason = "无法确认 IMS/VoLTE 能力：" + voiceErr.Error()
		return result
	}
	if result.Voice.VoLTECapability == 0 {
		result.Voice.Availability = "unsupported"
		result.Voice.Reason = "模块报告 VoLTE capability=0，WiSiM 已禁用通话；更换 SIM 后可重新检测"
		return result
	}

	missing := make([]string, 0, 4)
	if !result.Voice.ADBEnabled {
		missing = append(missing, "ADB")
	}
	if !result.Voice.UACEnabled {
		missing = append(missing, "USB 音频")
	}
	if !result.Voice.IMSEnabled {
		missing = append(missing, "IMS")
	}
	if !result.Voice.VoLTEEnabled {
		missing = append(missing, "VoLTE")
	}
	if len(missing) == 0 {
		result.Voice.Availability = "needs_runtime"
		result.Voice.Reason = "模块配置已就绪，仍需确认语音运行时和主机音频桥"
	} else {
		result.Voice.Availability = "needs_setup"
		result.Voice.Reason = "待启用：" + strings.Join(missing, "、")
	}
	result.Call = readCall(modem)
	return result
}

func readCall(modem usbModem) callInfo {
	response, err := modem.Command("AT+CLCC", 3*time.Second)
	if err != nil {
		return callInfo{State: "unknown"}
	}
	return parseCallResponse(response)
}

func parseCallResponse(response string) callInfo {
	re := regexp.MustCompile(`(?m)\+CLCC:\s*\d+\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*\d+(?:\s*,\s*"([^"]*)")?`)
	matches := re.FindAllStringSubmatch(response, -1)
	if len(matches) == 0 {
		return callInfo{State: "idle"}
	}
	for _, match := range matches {
		if len(match) < 4 || match[3] != "0" {
			// mode=0 才是语音；数据承载连接不能显示成通话。
			continue
		}
		number := ""
		if len(match) > 4 {
			number = strings.TrimSpace(match[4])
		}
		switch match[2] {
		case "4", "5":
			return callInfo{State: "incoming", Number: number, Incoming: true}
		case "2":
			return callInfo{State: "dialing", Number: number}
		case "3":
			return callInfo{State: "alerting", Number: number}
		case "0":
			return callInfo{State: "active", Number: number, Active: true}
		}
	}
	return callInfo{State: "idle"}
}

func normalizePhone(raw string) (string, bool) {
	value := strings.TrimSpace(raw)
	if len(value) < 3 || len(value) > 21 {
		return "", false
	}
	for index, r := range value {
		if r == '+' && index == 0 {
			continue
		}
		if r < '0' || r > '9' {
			return "", false
		}
	}
	return value, true
}

func commandFailure(action, response string, err error) error {
	if err != nil {
		return fmt.Errorf("%s失败：%w", action, err)
	}
	response = strings.TrimSpace(response)
	if response == "" {
		response = "模块未返回结果"
	}
	return fmt.Errorf("%s失败：%s", action, response)
}

func atSucceeded(response string) bool {
	upper := strings.ToUpper(strings.ReplaceAll(response, "\r\n", "\n"))
	return strings.HasSuffix(strings.TrimSpace(upper), "OK") && !strings.Contains(upper, "ERROR")
}

func firstCapture(value, pattern string) string {
	matches := regexp.MustCompile(pattern).FindStringSubmatch(value)
	if len(matches) < 2 {
		return ""
	}
	return strings.TrimSpace(matches[1])
}

func responseLines(response string) []string {
	normalized := strings.ReplaceAll(response, "\r", "")
	lines := strings.Split(normalized, "\n")
	result := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" && line != "OK" && !strings.HasPrefix(line, "AT") {
			result = append(result, line)
		}
	}
	return result
}
