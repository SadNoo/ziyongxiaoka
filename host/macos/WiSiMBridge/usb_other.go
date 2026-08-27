//go:build !darwin

package main

import "errors"

func openUSBModem() (usbModem, error) {
	return nil, errors.New("大疆 USB 桥目前只支持 macOS")
}
