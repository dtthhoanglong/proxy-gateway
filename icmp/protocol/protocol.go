package protocol

const (
	MessagePingRequest  = "PING_REQUEST"
	MessagePingResponse = "PING_RESPONSE"
)

type PingRequest struct {
	Type        string `json:"type"`
	ClientVM    string `json:"client_vm"`
	Destination string `json:"destination"`
	ID          uint16 `json:"id"`
	Sequence    uint16 `json:"sequence"`
	Payload     []byte `json:"payload"`
	TimeoutMS   int    `json:"timeout_ms"`
}

type PingResponse struct {
	Type        string  `json:"type"`
	ClientVM    string  `json:"client_vm"`
	Destination string  `json:"destination"`
	ID          uint16  `json:"id"`
	Sequence    uint16  `json:"sequence"`
	Success     bool    `json:"success"`
	RTTMS       float64 `json:"rtt_ms"`
	Error       string  `json:"error,omitempty"`
	Payload     []byte  `json:"payload,omitempty"`
}
