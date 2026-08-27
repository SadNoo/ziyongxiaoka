package main

import (
	"crypto/md5" // #nosec G501 -- QDC507 QADBKEY interoperability requires legacy MD5-crypt.
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	backupSchema        = 2
	backupKind          = "wisim-qdc507-usb-backup"
	preInitialize       = "pre_initialize"
	preRestore          = "pre_restore"
	qadbSecret          = "SH_adb_quectel"
	cryptMagic          = "$1$"
	cryptCharacters     = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	backupDirectoryName = "QDC507Backups"
)

type initializationInfo struct {
	ADBUACInitialized bool   `json:"adb_uac_initialized"`
	BackupAvailable   bool   `json:"backup_available"`
	BackupCount       int    `json:"backup_count"`
	LatestBackupAt    string `json:"latest_backup_at,omitempty"`
	CanInitialize     bool   `json:"can_initialize"`
	CanRestore        bool   `json:"can_restore"`
	State             string `json:"state"`
	Reason            string `json:"reason"`
}

type usbComposition struct {
	VendorID  int   `json:"vendor_id"`
	ProductID int   `json:"product_id"`
	Flags     []int `json:"flags"`
}

func (composition usbComposition) validate() error {
	if composition.VendorID <= 0 || composition.VendorID > 0xffff || composition.ProductID <= 0 || composition.ProductID > 0xffff {
		return errors.New("USB VID/PID 无效")
	}
	if len(composition.Flags) != 7 {
		return fmt.Errorf("USB 功能位数量为 %d，预期 7", len(composition.Flags))
	}
	for _, flag := range composition.Flags {
		if flag != 0 && flag != 1 {
			return errors.New("USB 配置包含非布尔功能位")
		}
	}
	return nil
}

func (composition usbComposition) command() string {
	values := []string{
		fmt.Sprintf("0x%04X", composition.VendorID),
		fmt.Sprintf("0x%04X", composition.ProductID),
	}
	for _, flag := range composition.Flags {
		values = append(values, strconv.Itoa(flag))
	}
	return `AT+QCFG="USBCFG",` + strings.Join(values, ",")
}

func (composition usbComposition) adbUACTarget() (usbComposition, error) {
	if err := composition.validate(); err != nil {
		return usbComposition{}, err
	}
	target := usbComposition{
		VendorID:  composition.VendorID,
		ProductID: composition.ProductID,
		Flags:     append([]int(nil), composition.Flags...),
	}
	target.Flags[5] = 1
	target.Flags[6] = 1
	return target, nil
}

func (composition usbComposition) equal(other usbComposition) bool {
	if composition.VendorID != other.VendorID || composition.ProductID != other.ProductID || len(composition.Flags) != len(other.Flags) {
		return false
	}
	for index := range composition.Flags {
		if composition.Flags[index] != other.Flags[index] {
			return false
		}
	}
	return true
}

type voiceConfiguration struct {
	IMS             int `json:"ims"`
	VoLTECapability int `json:"volte_capability"`
	VoLTEDisabled   int `json:"volte_disabled"`
}

func (configuration voiceConfiguration) validate() error {
	for name, value := range map[string]int{
		"IMS":              configuration.IMS,
		"VoLTE capability": configuration.VoLTECapability,
		"volte_disabled":   configuration.VoLTEDisabled,
	} {
		if value != 0 && value != 1 {
			return fmt.Errorf("%s 值 %d 无效", name, value)
		}
	}
	return nil
}

type moduleIdentity struct {
	IMEI     string `json:"imei"`
	Firmware string `json:"firmware"`
}

type moduleBackup struct {
	SchemaVersion  int                `json:"schema_version"`
	Kind           string             `json:"kind"`
	Purpose        string             `json:"purpose"`
	SavedAt        time.Time          `json:"saved_at"`
	Module         moduleIdentity     `json:"module"`
	USB            usbComposition     `json:"usb"`
	Voice          voiceConfiguration `json:"voice"`
	RestoreCommand string             `json:"restore_command"`
}

type deviceOperationResult struct {
	Status          string `json:"status"`
	Stage           string `json:"stage"`
	Message         string `json:"message,omitempty"`
	IMEISuffix      string `json:"imei_suffix,omitempty"`
	BackupCount     int    `json:"backup_count,omitempty"`
	Changed         bool   `json:"changed"`
	RebootRequested bool   `json:"reboot_requested"`
	Error           string `json:"error,omitempty"`
}

func runDeviceOperation(args []string) (deviceOperationResult, error) {
	if len(args) != 3 {
		return deviceOperationResult{Stage: "usage"}, errors.New("初始化或恢复命令参数无效")
	}
	switch args[0] {
	case "initialize-usb":
		if args[2] != "--confirm-adb-uac" {
			return deviceOperationResult{Stage: "initialize-usb"}, errors.New("缺少 ADB/UAC 初始化确认参数")
		}
		return initializeUSB(args[1])
	case "restore-usb":
		if args[2] != "--confirm-restore" {
			return deviceOperationResult{Stage: "restore-usb"}, errors.New("缺少 USB 配置恢复确认参数")
		}
		return restoreUSB(args[1])
	default:
		return deviceOperationResult{Stage: "usage"}, fmt.Errorf("未知设备操作 %q", args[0])
	}
}

func initializeUSB(directory string) (deviceOperationResult, error) {
	modem, err := openUSBModem()
	if err != nil {
		return deviceOperationResult{Stage: "initialize-usb"}, err
	}
	defer modem.Close()

	identity, current, voice, err := inspectDeviceConfiguration(modem)
	result := deviceOperationResult{Stage: "initialize-usb", IMEISuffix: imeiSuffix(identity.IMEI)}
	if err != nil {
		return result, err
	}
	if hasVoiceCall(modem) {
		return result, errors.New("模块存在语音通话，已停止初始化")
	}
	target, err := current.adbUACTarget()
	if err != nil {
		return result, err
	}
	if current.equal(target) {
		result.Status = "ok"
		result.Message = "ADB 与 USB 音频已经启用，没有写入设备"
		return result, nil
	}
	if _, err := writeBackup(directory, preInitialize, identity, current, voice); err != nil {
		return result, fmt.Errorf("创建写入前备份：%w", err)
	}
	backups, _ := matchingBackups(directory, identity.IMEI, preInitialize)
	result.BackupCount = len(backups)
	if err := submitQADB(modem); err != nil {
		return result, err
	}
	if err := writeUSBConfiguration(modem, current, target); err != nil {
		return result, err
	}
	actualVoice, err := readVoiceConfiguration(modem)
	if err != nil {
		return result, err
	}
	if actualVoice != voice {
		return result, errors.New("IMS/VoLTE 在 USB 初始化后意外变化，已停止重启")
	}
	if err := rebootModem(modem); err != nil {
		return result, err
	}
	result.Status = "ok"
	result.Changed = true
	result.RebootRequested = true
	result.Message = "已保留 VID/PID 和其他功能位，仅启用 ADB 与 USB 音频；模块正在重启"
	return result, nil
}

func restoreUSB(directory string) (deviceOperationResult, error) {
	modem, err := openUSBModem()
	if err != nil {
		return deviceOperationResult{Stage: "restore-usb"}, err
	}
	defer modem.Close()

	identity, current, voice, err := inspectDeviceConfiguration(modem)
	result := deviceOperationResult{Stage: "restore-usb", IMEISuffix: imeiSuffix(identity.IMEI)}
	if err != nil {
		return result, err
	}
	if hasVoiceCall(modem) {
		return result, errors.New("模块存在语音通话，已停止恢复")
	}
	backups, err := matchingBackups(directory, identity.IMEI, preInitialize)
	if err != nil {
		return result, err
	}
	result.BackupCount = len(backups)
	if len(backups) == 0 {
		return result, errors.New("没有找到与当前模块匹配的 WiSiM 写入前备份")
	}
	backup := backups[len(backups)-1]
	if current.VendorID != backup.USB.VendorID || current.ProductID != backup.USB.ProductID {
		return result, errors.New("当前模块 VID/PID 与备份不一致，已停止恢复")
	}
	if voice != backup.Voice {
		return result, errors.New("当前 IMS/VoLTE 与写入前备份不一致，已停止恢复；WiSiM 不会覆盖语音配置")
	}
	if current.equal(backup.USB) {
		result.Status = "ok"
		result.Message = "当前 USB 配置已经与写入前备份一致，没有写入设备"
		return result, nil
	}
	if _, err := writeBackup(directory, preRestore, identity, current, voice); err != nil {
		return result, fmt.Errorf("创建恢复前保护备份：%w", err)
	}
	if err := submitQADB(modem); err != nil {
		return result, err
	}
	if err := writeUSBConfiguration(modem, current, backup.USB); err != nil {
		return result, err
	}
	actualVoice, err := readVoiceConfiguration(modem)
	if err != nil {
		return result, err
	}
	if actualVoice != voice {
		return result, errors.New("IMS/VoLTE 在 USB 恢复后意外变化，已停止重启")
	}
	if err := rebootModem(modem); err != nil {
		return result, err
	}
	result.Status = "ok"
	result.Changed = true
	result.RebootRequested = true
	result.Message = "已恢复写入前 USB 配置；模块正在重启。QADBKEY 持久授权不保证随接口关闭而撤销"
	return result, nil
}

func inspectInitialization(directory, imei string, current *usbComposition, adbEnabled, uacEnabled bool) initializationInfo {
	initialized := adbEnabled && uacEnabled
	result := initializationInfo{
		ADBUACInitialized: initialized,
		State:             "unavailable",
		Reason:            "无法读取完整 USB 配置",
	}
	if current == nil || len(imei) != 15 {
		return result
	}
	backups, err := matchingBackups(directory, imei, preInitialize)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		result.Reason = "备份状态不可用：" + err.Error()
		return result
	}
	result.BackupCount = len(backups)
	result.BackupAvailable = len(backups) > 0
	if len(backups) > 0 {
		result.LatestBackupAt = backups[len(backups)-1].SavedAt.Format(time.RFC3339)
	}
	result.CanInitialize = !initialized
	result.CanRestore = initialized && result.BackupAvailable
	switch {
	case initialized && result.BackupAvailable:
		result.State = "initialized_with_backup"
		result.Reason = "ADB 与 USB 音频已启用，可恢复写入前 USB 配置"
	case initialized:
		result.State = "initialized_without_backup"
		result.Reason = "ADB 与 USB 音频已启用，但未发现由 WiSiM 创建的写入前备份"
	case adbEnabled || uacEnabled:
		result.State = "partially_initialized"
		result.Reason = "ADB 与 USB 音频只有一项启用；初始化前会先创建完整备份"
	default:
		result.State = "ready_to_initialize"
		result.Reason = "可先创建本机私有备份，再仅启用 ADB 与 USB 音频"
	}
	return result
}

func inspectDeviceConfiguration(modem usbModem) (moduleIdentity, usbComposition, voiceConfiguration, error) {
	imeiResponse, err := modem.Command("AT+CGSN", 4*time.Second)
	if err != nil {
		return moduleIdentity{}, usbComposition{}, voiceConfiguration{}, fmt.Errorf("读取 IMEI：%w", err)
	}
	imei := firstCapture(imeiResponse, `(?m)^\s*([0-9]{15})\s*$`)
	if len(imei) != 15 {
		return moduleIdentity{}, usbComposition{}, voiceConfiguration{}, errors.New("模块没有返回有效的 15 位 IMEI")
	}
	firmware := ""
	if response, commandErr := modem.Command("ATI", 4*time.Second); commandErr == nil {
		firmware = firstCapture(response, `(?im)^\s*Revision:\s*([^\r\n]+)`)
	}
	usbResponse, err := modem.Command(`AT+QCFG="USBCFG"`, 5*time.Second)
	if err != nil {
		return moduleIdentity{}, usbComposition{}, voiceConfiguration{}, fmt.Errorf("读取 USBCFG：%w", err)
	}
	usb, err := parseUSBComposition(usbResponse)
	if err != nil {
		return moduleIdentity{}, usbComposition{}, voiceConfiguration{}, err
	}
	voice, err := readVoiceConfiguration(modem)
	if err != nil {
		return moduleIdentity{}, usbComposition{}, voiceConfiguration{}, err
	}
	return moduleIdentity{IMEI: imei, Firmware: firmware}, usb, voice, nil
}

func readVoiceConfiguration(modem usbModem) (voiceConfiguration, error) {
	imsResponse, err := modem.Command(`AT+QCFG="ims"`, 5*time.Second)
	if err != nil {
		return voiceConfiguration{}, fmt.Errorf("读取 IMS：%w", err)
	}
	imsMatches := regexp.MustCompile(`(?im)\+QCFG:\s*"ims"\s*,\s*([01])\s*,\s*([01])`).FindStringSubmatch(imsResponse)
	if len(imsMatches) != 3 {
		return voiceConfiguration{}, errors.New("无法解析 IMS/VoLTE 能力")
	}
	ims, _ := strconv.Atoi(imsMatches[1])
	capability, _ := strconv.Atoi(imsMatches[2])
	volteResponse, err := modem.Command(`AT+QCFG="volte_disable"`, 5*time.Second)
	if err != nil {
		return voiceConfiguration{}, fmt.Errorf("读取 VoLTE 开关：%w", err)
	}
	disabledRaw := firstCapture(strings.ReplaceAll(volteResponse, "_", "/"), `(?im)\+QCFG:\s*"volte/disable"\s*,\s*([01])`)
	if disabledRaw == "" {
		return voiceConfiguration{}, errors.New("无法解析 VoLTE 开关")
	}
	disabled, _ := strconv.Atoi(disabledRaw)
	configuration := voiceConfiguration{IMS: ims, VoLTECapability: capability, VoLTEDisabled: disabled}
	return configuration, configuration.validate()
}

func parseUSBComposition(response string) (usbComposition, error) {
	pattern := regexp.MustCompile(`(?im)\+QCFG:\s*"usbcfg"\s*,\s*(0x[0-9a-f]+|[0-9]+)\s*,\s*(0x[0-9a-f]+|[0-9]+)\s*,\s*([01])\s*,\s*([01])\s*,\s*([01])\s*,\s*([01])\s*,\s*([01])\s*,\s*([01])\s*,\s*([01])`)
	matches := pattern.FindStringSubmatch(response)
	if len(matches) != 10 {
		return usbComposition{}, errors.New("无法解析完整 USBCFG")
	}
	parse := func(raw string) (int, error) {
		value, err := strconv.ParseInt(raw, 0, 32)
		return int(value), err
	}
	vendor, err := parse(matches[1])
	if err != nil {
		return usbComposition{}, err
	}
	product, err := parse(matches[2])
	if err != nil {
		return usbComposition{}, err
	}
	flags := make([]int, 7)
	for index := range flags {
		flags[index], _ = strconv.Atoi(matches[index+3])
	}
	composition := usbComposition{VendorID: vendor, ProductID: product, Flags: flags}
	return composition, composition.validate()
}

func writeUSBConfiguration(modem usbModem, original, target usbComposition) error {
	if err := original.validate(); err != nil {
		return err
	}
	if err := target.validate(); err != nil {
		return err
	}
	if original.VendorID != target.VendorID || original.ProductID != target.ProductID {
		return errors.New("安全策略禁止修改 USB VID/PID")
	}
	response, commandErr := modem.Command(target.command(), 8*time.Second)
	if commandErr != nil || !atSucceeded(response) {
		return operationCommandError("USB 配置写入失败", response, commandErr)
	}
	readBackResponse, readErr := modem.Command(`AT+QCFG="USBCFG"`, 5*time.Second)
	if readErr != nil {
		return fmt.Errorf("USB 配置回读失败：%w", readErr)
	}
	readBack, parseErr := parseUSBComposition(readBackResponse)
	if parseErr != nil {
		return parseErr
	}
	if !readBack.equal(target) {
		return errors.New("USB 配置回读与目标不一致，已停止重启")
	}
	return nil
}

func rebootModem(modem usbModem) error {
	response, commandErr := modem.Command("AT+CFUN=1,1", 5*time.Second)
	if commandErr == nil && responseContainsATError(response) {
		return errors.New("模块拒绝重启命令")
	}
	// 模块接受重启后可能立即断开 USB，使读取端得到超时；这不代表写入失败。
	return nil
}

func hasVoiceCall(modem usbModem) bool {
	response, err := modem.Command("AT+CLCC", 4*time.Second)
	if err != nil {
		return true
	}
	pattern := regexp.MustCompile(`(?m)\+CLCC:\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*(\d+)\s*(?:,|$)`)
	for _, match := range pattern.FindAllStringSubmatch(response, -1) {
		if len(match) == 2 && match[1] == "0" {
			return true
		}
	}
	return false
}

func writeBackup(directory, purpose string, identity moduleIdentity, usb usbComposition, voice voiceConfiguration) (moduleBackup, error) {
	absolute, err := secureBackupDirectory(directory, true)
	if err != nil {
		return moduleBackup{}, err
	}
	backup := moduleBackup{
		SchemaVersion:  backupSchema,
		Kind:           backupKind,
		Purpose:        purpose,
		SavedAt:        time.Now(),
		Module:         identity,
		USB:            usb,
		Voice:          voice,
		RestoreCommand: usb.command(),
	}
	if err := validateBackup(backup); err != nil {
		return moduleBackup{}, err
	}
	payload, err := json.MarshalIndent(backup, "", "  ")
	if err != nil {
		return moduleBackup{}, err
	}
	payload = append(payload, '\n')
	path := filepath.Join(absolute, purpose+"-"+backup.SavedAt.Format("20060102-150405.000000000")+".json")
	temporary, err := os.CreateTemp(absolute, ".backup-*.tmp")
	if err != nil {
		return moduleBackup{}, err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return moduleBackup{}, err
	}
	if _, err := temporary.Write(payload); err != nil {
		_ = temporary.Close()
		return moduleBackup{}, err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return moduleBackup{}, err
	}
	if err := temporary.Close(); err != nil {
		return moduleBackup{}, err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return moduleBackup{}, err
	}
	return backup, nil
}

func matchingBackups(directory, imei, purpose string) ([]moduleBackup, error) {
	if directory == "" {
		return nil, nil
	}
	absolute, err := secureBackupDirectory(directory, false)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(absolute)
	if err != nil {
		return nil, err
	}
	backups := make([]moduleBackup, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		backup, readErr := readBackup(filepath.Join(absolute, entry.Name()))
		if readErr != nil || backup.Module.IMEI != imei || backup.Purpose != purpose {
			continue
		}
		backups = append(backups, backup)
	}
	sort.Slice(backups, func(left, right int) bool { return backups[left].SavedAt.Before(backups[right].SavedAt) })
	return backups, nil
}

func secureBackupDirectory(directory string, create bool) (string, error) {
	if directory == "" {
		return "", errors.New("未提供备份目录")
	}
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}
	if filepath.Base(absolute) != backupDirectoryName {
		return "", fmt.Errorf("备份目录必须命名为 %s", backupDirectoryName)
	}
	if create {
		if err := os.MkdirAll(absolute, 0o700); err != nil {
			return "", err
		}
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("备份路径不是普通目录")
	}
	if info.Mode().Perm()&0o077 != 0 {
		if !create {
			return "", errors.New("备份目录权限过宽，要求 0700")
		}
		if err := os.Chmod(absolute, 0o700); err != nil {
			return "", err
		}
	}
	return absolute, nil
}

func readBackup(path string) (moduleBackup, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return moduleBackup{}, err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 64<<10 {
		return moduleBackup{}, errors.New("备份文件类型或大小无效")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return moduleBackup{}, errors.New("备份文件权限过宽，要求 0600")
	}
	payload, err := os.ReadFile(path)
	if err != nil {
		return moduleBackup{}, err
	}
	var backup moduleBackup
	if err := json.Unmarshal(payload, &backup); err != nil {
		return moduleBackup{}, err
	}
	return backup, validateBackup(backup)
}

func validateBackup(backup moduleBackup) error {
	if backup.SchemaVersion != backupSchema || backup.Kind != backupKind || backup.SavedAt.IsZero() {
		return errors.New("备份格式无效")
	}
	if backup.Purpose != preInitialize && backup.Purpose != preRestore {
		return errors.New("备份用途无效")
	}
	if !regexp.MustCompile(`^[0-9]{15}$`).MatchString(backup.Module.IMEI) {
		return errors.New("备份 IMEI 无效")
	}
	if err := backup.USB.validate(); err != nil {
		return err
	}
	if err := backup.Voice.validate(); err != nil {
		return err
	}
	if backup.RestoreCommand != backup.USB.command() {
		return errors.New("备份还原命令与 USB 配置不一致")
	}
	return nil
}

func submitQADB(modem usbModem) error {
	response, err := modem.Command("AT+QADBKEY?", 4*time.Second)
	if err != nil {
		return fmt.Errorf("读取 ADB 授权挑战：%w", err)
	}
	challenge, err := parseQADBChallenge(response)
	if err != nil {
		return err
	}
	password, err := qadbPassword(challenge)
	challenge = ""
	if err != nil {
		return err
	}
	command := fmt.Sprintf(`AT+QADBKEY="%s"`, password)
	response, commandErr := modem.Command(command, 8*time.Second)
	accepted := commandErr == nil && atSucceeded(response)
	password, command, response = "", "", ""
	if !accepted {
		if commandErr != nil {
			return fmt.Errorf("无法确认 ADB 授权结果：%w；授权密码未记录", commandErr)
		}
		return errors.New("模块拒绝 ADB 授权；授权密码未记录")
	}
	return nil
}

func parseQADBChallenge(response string) (string, error) {
	if !atSucceeded(response) {
		return "", errors.New("QADBKEY 查询未返回 OK")
	}
	matches := regexp.MustCompile(`(?im)^\s*\+QADBKEY:\s*([0-9]{8})\s*$`).FindAllStringSubmatch(response, 2)
	if len(matches) != 1 || len(matches[0]) != 2 {
		return "", errors.New("模块没有返回唯一的 8 位 QADBKEY 挑战")
	}
	return matches[0][1], nil
}

func qadbPassword(challenge string) (string, error) {
	if !regexp.MustCompile(`^[0-9]{8}$`).MatchString(challenge) {
		return "", errors.New("QADBKEY 挑战格式无效")
	}
	hash := md5Crypt([]byte(qadbSecret), []byte(challenge))
	prefix := cryptMagic + challenge + "$"
	if !strings.HasPrefix(hash, prefix) || len(hash) < len(prefix)+15 {
		return "", errors.New("无法生成 QADBKEY 响应")
	}
	return hash[len(prefix) : len(prefix)+15], nil
}

func md5Crypt(password, salt []byte) string {
	initial := md5.New() // #nosec G401 -- modem protocol requirement.
	_, _ = initial.Write(password)
	_, _ = initial.Write([]byte(cryptMagic))
	_, _ = initial.Write(salt)
	alternate := md5.New() // #nosec G401 -- modem protocol requirement.
	_, _ = alternate.Write(password)
	_, _ = alternate.Write(salt)
	_, _ = alternate.Write(password)
	alternateSum := alternate.Sum(nil)
	for remaining := len(password); remaining > 0; remaining -= md5.Size {
		count := remaining
		if count > md5.Size {
			count = md5.Size
		}
		_, _ = initial.Write(alternateSum[:count])
	}
	for count := len(password); count > 0; count >>= 1 {
		if count&1 != 0 {
			_, _ = initial.Write([]byte{0})
		} else {
			_, _ = initial.Write(password[:1])
		}
	}
	digest := initial.Sum(nil)
	for round := 0; round < 1000; round++ {
		current := md5.New() // #nosec G401 -- modem protocol requirement.
		if round&1 != 0 {
			_, _ = current.Write(password)
		} else {
			_, _ = current.Write(digest)
		}
		if round%3 != 0 {
			_, _ = current.Write(salt)
		}
		if round%7 != 0 {
			_, _ = current.Write(password)
		}
		if round&1 != 0 {
			_, _ = current.Write(digest)
		} else {
			_, _ = current.Write(password)
		}
		digest = current.Sum(nil)
	}
	var encoded strings.Builder
	writeCrypt64(&encoded, digest[0], digest[6], digest[12], 4)
	writeCrypt64(&encoded, digest[1], digest[7], digest[13], 4)
	writeCrypt64(&encoded, digest[2], digest[8], digest[14], 4)
	writeCrypt64(&encoded, digest[3], digest[9], digest[15], 4)
	writeCrypt64(&encoded, digest[4], digest[10], digest[5], 4)
	writeCrypt64(&encoded, 0, 0, digest[11], 2)
	return cryptMagic + string(salt) + "$" + encoded.String()
}

func writeCrypt64(output *strings.Builder, high, middle, low byte, count int) {
	value := uint32(high)<<16 | uint32(middle)<<8 | uint32(low)
	for index := 0; index < count; index++ {
		output.WriteByte(cryptCharacters[value&0x3f])
		value >>= 6
	}
}

func responseContainsATError(response string) bool {
	upper := strings.ToUpper(strings.ReplaceAll(response, "\r", ""))
	return strings.Contains(upper, "\nERROR") || strings.Contains(upper, "+CME ERROR:") || strings.Contains(upper, "+CMS ERROR:")
}

func operationCommandError(label, response string, err error) error {
	if err != nil {
		return fmt.Errorf("%s：%w", label, err)
	}
	if responseContainsATError(response) {
		return fmt.Errorf("%s：模块返回 ERROR", label)
	}
	return fmt.Errorf("%s：模块未返回完整 OK", label)
}

func imeiSuffix(imei string) string {
	if len(imei) < 4 {
		return ""
	}
	return imei[len(imei)-4:]
}
