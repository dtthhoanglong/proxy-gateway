package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"time"

	"github.com/dtthhoanglong/proxy-gateway/icmp/protocol"
	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

const listenAddr = ":18443"

func main() {
	log.Printf("ICMP Relay Server listening on %s", listenAddr)

	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("listen failed: %v", err)
	}
	defer listener.Close()

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("accept failed: %v", err)
			continue
		}

		go handleConnection(conn)
	}
}

func handleConnection(conn net.Conn) {
	defer conn.Close()

	log.Printf("TCP connection from %s", conn.RemoteAddr())

	decoder := json.NewDecoder(conn)
	encoder := json.NewEncoder(conn)

	var req protocol.PingRequest

	if err := decoder.Decode(&req); err != nil {
		log.Printf("decode request failed: %v", err)
		return
	}

	if req.Type != protocol.MessagePingRequest {
		log.Printf("invalid message type: %s", req.Type)
		return
	}

	resp := performPing(&req)

	if err := encoder.Encode(resp); err != nil {
		log.Printf("send response failed: %v", err)
		return
	}
}

func performPing(req *protocol.PingRequest) protocol.PingResponse {
	resp := protocol.PingResponse{
		Type:        protocol.MessagePingResponse,
		Destination: req.Destination,
		ID:          req.ID,
		Sequence:    req.Sequence,
	}

	timeout := 3 * time.Second

	if req.TimeoutMS > 0 {
		timeout = time.Duration(req.TimeoutMS) * time.Millisecond
	}

	dst, err := net.ResolveIPAddr("ip4", req.Destination)
	if err != nil {
		resp.Error = fmt.Sprintf("resolve destination failed: %v", err)
		return resp
	}

	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		resp.Error = fmt.Sprintf("open ICMP socket failed: %v", err)
		return resp
	}
	defer conn.Close()

	message := icmp.Message{
		Type: ipv4.ICMPTypeEcho,
		Code: 0,
		Body: &icmp.Echo{
			ID:   int(req.ID),
			Seq:  int(req.Sequence),
			Data: req.Payload,
		},
	}

	packet, err := message.Marshal(nil)
	if err != nil {
		resp.Error = fmt.Sprintf("marshal ICMP packet failed: %v", err)
		return resp
	}

	start := time.Now()

	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		resp.Error = fmt.Sprintf("set deadline failed: %v", err)
		return resp
	}

	if _, err := conn.WriteTo(packet, dst); err != nil {
		resp.Error = fmt.Sprintf("send ICMP failed: %v", err)
		return resp
	}

	reply := make([]byte, 1500)

	for {
		n, peer, err := conn.ReadFrom(reply)
		if err != nil {
			resp.Error = fmt.Sprintf("ICMP timeout/error: %v", err)
			return resp
		}

		parsed, err := icmp.ParseMessage(1, reply[:n])
		if err != nil {
			continue
		}

		if parsed.Type != ipv4.ICMPTypeEchoReply {
			continue
		}

		echo, ok := parsed.Body.(*icmp.Echo)
		if !ok {
			continue
		}

		if echo.ID != int(req.ID) || echo.Seq != int(req.Sequence) {
			continue
		}

		resp.Success = true
		resp.RTTMS = float64(time.Since(start).Microseconds()) / 1000.0
		resp.Payload = echo.Data

		log.Printf(
			"PING %s: reply from %s, seq=%d, rtt=%.3f ms",
			req.Destination,
			peer,
			req.Sequence,
			resp.RTTMS,
		)

		return resp
	}
}
