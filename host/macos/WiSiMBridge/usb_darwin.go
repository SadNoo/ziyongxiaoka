//go:build darwin

package main

/*
#cgo LDFLAGS: -lusb-1.0
#include <libusb.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
	"unsafe"
)

type usbCandidate struct {
	interfaceNumber int
	inputEndpoint   byte
	outputEndpoint  byte
}

type darwinUSBModem struct {
	context         *C.libusb_context
	handle          *C.libusb_device_handle
	interfaceNumber int
	inputEndpoint   byte
	outputEndpoint  byte
	usbID           string
	mutex           sync.Mutex
}

func openUSBModem() (usbModem, error) {
	var context *C.libusb_context
	if result := C.libusb_init(&context); result != 0 {
		return nil, fmt.Errorf("初始化 USB：%s", usbErrorName(result))
	}
	ids := []struct {
		vendor  C.uint16_t
		product C.uint16_t
		label   string
	}{
		{0x2ca3, 0x4006, "2ca3:4006"},
		{0x2c7c, 0x0125, "2c7c:0125"},
	}
	var lastError error
	for _, id := range ids {
		handle := C.libusb_open_device_with_vid_pid(context, id.vendor, id.product)
		if handle == nil {
			continue
		}
		candidates, err := readUSBCandidates(handle)
		if err != nil {
			lastError = err
			C.libusb_close(handle)
			continue
		}
		for _, candidate := range candidates {
			if result := C.libusb_claim_interface(handle, C.int(candidate.interfaceNumber)); result != 0 {
				lastError = fmt.Errorf("占用 USB AT 接口 %d：%s", candidate.interfaceNumber, usbErrorName(result))
				continue
			}
			modem := &darwinUSBModem{
				context:         context,
				handle:          handle,
				interfaceNumber: candidate.interfaceNumber,
				inputEndpoint:   candidate.inputEndpoint,
				outputEndpoint:  candidate.outputEndpoint,
				usbID:           id.label,
			}
			response, probeError := modem.Command("AT", 1200*time.Millisecond)
			if probeError == nil && atSucceeded(response) {
				return modem, nil
			}
			C.libusb_release_interface(handle, C.int(candidate.interfaceNumber))
			if probeError != nil {
				lastError = probeError
			}
		}
		C.libusb_close(handle)
	}
	C.libusb_exit(context)
	if lastError != nil {
		return nil, fmt.Errorf("已检测到大疆模块，但 AT 接口不可用：%w", lastError)
	}
	return nil, errors.New("未检测到大疆 QDC507（支持 USB 2ca3:4006 与 2c7c:0125）")
}

func readUSBCandidates(handle *C.libusb_device_handle) ([]usbCandidate, error) {
	device := C.libusb_get_device(handle)
	if device == nil {
		return nil, errors.New("USB 句柄没有关联设备")
	}
	var configuration *C.struct_libusb_config_descriptor
	if result := C.libusb_get_active_config_descriptor(device, &configuration); result != 0 {
		return nil, fmt.Errorf("读取 USB 配置：%s", usbErrorName(result))
	}
	defer C.libusb_free_config_descriptor(configuration)

	interfaces := unsafe.Slice(configuration._interface, int(configuration.bNumInterfaces))
	result := make([]usbCandidate, 0, 2)
	for _, usbInterface := range interfaces {
		alternates := unsafe.Slice(usbInterface.altsetting, int(usbInterface.num_altsetting))
		for _, alternate := range alternates {
			// QDC507 的 AT 和 modem 通道位于 2/3。只探测这两个接口，避免读取诊断口。
			if alternate.bInterfaceNumber != 2 && alternate.bInterfaceNumber != 3 {
				continue
			}
			if byte(alternate.bInterfaceClass) != 0xff || byte(alternate.bInterfaceSubClass) != 0x00 {
				continue
			}
			var inputEndpoint, outputEndpoint byte
			endpoints := unsafe.Slice(alternate.endpoint, int(alternate.bNumEndpoints))
			for _, endpoint := range endpoints {
				if byte(endpoint.bmAttributes)&0x03 != 0x02 {
					continue
				}
				address := byte(endpoint.bEndpointAddress)
				if address&0x80 != 0 {
					inputEndpoint = address
				} else {
					outputEndpoint = address
				}
			}
			if inputEndpoint != 0 && outputEndpoint != 0 {
				result = append(result, usbCandidate{
					interfaceNumber: int(alternate.bInterfaceNumber),
					inputEndpoint:   inputEndpoint,
					outputEndpoint:  outputEndpoint,
				})
			}
		}
	}
	return result, nil
}

func (modem *darwinUSBModem) USBID() string { return modem.usbID }

func (modem *darwinUSBModem) Close() {
	modem.mutex.Lock()
	defer modem.mutex.Unlock()
	if modem.handle == nil {
		return
	}
	C.libusb_release_interface(modem.handle, C.int(modem.interfaceNumber))
	C.libusb_close(modem.handle)
	C.libusb_exit(modem.context)
	modem.handle = nil
	modem.context = nil
}

func (modem *darwinUSBModem) Command(command string, timeout time.Duration) (string, error) {
	command = strings.TrimSpace(command)
	if command == "" || !strings.HasPrefix(strings.ToUpper(command), "AT") {
		return "", errors.New("AT 命令无效")
	}
	if timeout <= 0 {
		timeout = 3 * time.Second
	}

	modem.mutex.Lock()
	defer modem.mutex.Unlock()
	if modem.handle == nil {
		return "", errors.New("USB AT 接口已关闭")
	}
	modem.drain()
	payload := []byte(command + "\r")
	if err := modem.write(payload, timeout); err != nil {
		return "", err
	}

	deadline := time.Now().Add(timeout)
	var response strings.Builder
	for time.Now().Before(deadline) {
		remaining := time.Until(deadline)
		if remaining > 600*time.Millisecond {
			remaining = 600 * time.Millisecond
		}
		chunk, err := modem.read(remaining)
		if err != nil {
			if errors.Is(err, errUSBTimeout) {
				continue
			}
			return strings.TrimSpace(response.String()), err
		}
		response.Write(chunk)
		if completeATResponse(response.String()) {
			return strings.TrimSpace(response.String()), nil
		}
	}
	if response.Len() == 0 {
		return "", errors.New("USB AT 命令等待响应超时")
	}
	return strings.TrimSpace(response.String()), errors.New("USB AT 响应未完整结束")
}

var errUSBTimeout = errors.New("USB timeout")

func (modem *darwinUSBModem) drain() {
	for {
		if _, err := modem.read(60 * time.Millisecond); err != nil {
			return
		}
	}
}

func (modem *darwinUSBModem) write(payload []byte, timeout time.Duration) error {
	var transferred C.int
	result := C.libusb_bulk_transfer(
		modem.handle,
		C.uchar(modem.outputEndpoint),
		(*C.uchar)(unsafe.Pointer(&payload[0])),
		C.int(len(payload)),
		&transferred,
		C.uint(max(int(timeout.Milliseconds()), 1)),
	)
	if result != 0 {
		return fmt.Errorf("USB 写入：%s", usbErrorName(result))
	}
	if int(transferred) != len(payload) {
		return fmt.Errorf("USB 写入不完整：%d/%d", int(transferred), len(payload))
	}
	return nil
}

func (modem *darwinUSBModem) read(timeout time.Duration) ([]byte, error) {
	buffer := make([]byte, 1024)
	var transferred C.int
	result := C.libusb_bulk_transfer(
		modem.handle,
		C.uchar(modem.inputEndpoint),
		(*C.uchar)(unsafe.Pointer(&buffer[0])),
		C.int(len(buffer)),
		&transferred,
		C.uint(max(int(timeout.Milliseconds()), 1)),
	)
	if result == C.LIBUSB_ERROR_TIMEOUT {
		return nil, errUSBTimeout
	}
	if result != 0 {
		return nil, fmt.Errorf("USB 读取：%s", usbErrorName(result))
	}
	return buffer[:int(transferred)], nil
}

func completeATResponse(response string) bool {
	normalized := strings.ToUpper(strings.ReplaceAll(response, "\r\n", "\n"))
	return strings.Contains(normalized, "\nOK\n") ||
		strings.HasSuffix(strings.TrimSpace(normalized), "OK") ||
		strings.Contains(normalized, "\nERROR") ||
		strings.Contains(normalized, "+CME ERROR:") ||
		strings.Contains(normalized, "+CMS ERROR:")
}

func usbErrorName(result C.int) string { return C.GoString(C.libusb_error_name(result)) }
