package main

import "testing"

func TestNormalizePhone(t *testing.T) {
	tests := []struct {
		input string
		valid bool
	}{
		{"+999000000000", true},
		{"10086", true},
		{"12", false},
		{"+86 138", false},
		{"138-0013-8000", false},
		{"++86138", false},
	}
	for _, test := range tests {
		_, valid := normalizePhone(test.input)
		if valid != test.valid {
			t.Fatalf("normalizePhone(%q) valid=%v, want %v", test.input, valid, test.valid)
		}
	}
}

func TestParseCallResponse(t *testing.T) {
	tests := []struct {
		name     string
		response string
		state    string
		number   string
		incoming bool
		active   bool
	}{
		{"idle", "AT+CLCC\r\r\nOK\r\n", "idle", "", false, false},
		{"incoming", "+CLCC: 1,1,4,0,0,\"+999000000000\",145\r\nOK\r\n", "incoming", "+999000000000", true, false},
		{"dialing", "+CLCC: 1,0,2,0,0,\"10086\",129\r\nOK\r\n", "dialing", "10086", false, false},
		{"active without number", "+CLCC: 1,0,0,0,0\r\nOK\r\n", "active", "", false, true},
		{"packet data is not a call", "+CLCC: 1,0,0,1,0\r\nOK\r\n", "idle", "", false, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := parseCallResponse(test.response)
			if result.State != test.state || result.Number != test.number || result.Incoming != test.incoming || result.Active != test.active {
				t.Fatalf("result=%+v", result)
			}
		})
	}
}

func TestATSucceeded(t *testing.T) {
	if !atSucceeded("AT\r\r\nOK\r\n") {
		t.Fatal("expected OK")
	}
	if atSucceeded("AT\r\r\nERROR\r\n") {
		t.Fatal("ERROR must fail")
	}
}

func TestResponseLines(t *testing.T) {
	lines := responseLines("ATI\r\nRevision: QDC507GLEFM21\r\nOK\r\n")
	if len(lines) != 1 || lines[0] != "Revision: QDC507GLEFM21" {
		t.Fatalf("lines=%v", lines)
	}
}
