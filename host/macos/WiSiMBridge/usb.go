package main

import "time"

type usbModem interface {
	Command(command string, timeout time.Duration) (string, error)
	USBID() string
	Close()
}
