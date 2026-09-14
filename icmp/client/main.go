package main

import (
	"encoding/json"
	"fmt"
	"github.com/dtthhoanglong/proxy-gateway/icmp/protocol"
	"log"
	"net"
	"time"
)

const relayAddr = "192.168.2.17:18443"

func main() {
	destination := "8.8.8.8"
	clientVM := "VM101"
	req := protocol.PingRequest{
		Type:        protocol.MessagePingRequest,
		ClientVM:    clientVM,
		Destination: destination,
		ID:          uint16(time.Now().UnixNano() & 0xffff),
		Sequence:    1,
		Payload:     []byte("proxy-gateway-icmp-v2"),
		TimeoutMS:   3000,
	}

	log.Printf("Connecting to Relay Server %s", relayAddr)

	conn, err := net.DialTimeout("tcp", relayAddr, 5*time.Second)
	if err != nil {
		log.Fatalf("connect to relay failed: %v", err)
	}
	defer conn.Close()

	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		log.Fatalf("set connection deadline failed: %v", err)
	}

	encoder := json.NewEncoder(conn)
	decoder := json.NewDecoder(conn)

	start := time.Now()

	if err := encoder.Encode(req); err != nil {
		log.Fatalf("send PING_REQUEST failed: %v", err)
	}

	var resp protocol.PingResponse

	if err := decoder.Decode(&resp); err != nil {
		log.Fatalf("receive PING_RESPONSE failed: %v", err)
	}

	elapsed := time.Since(start)

	fmt.Println()
	fmt.Println("========================================")
	fmt.Println("        ICMP RELAY TEST RESULT")
	fmt.Println("========================================")
	fmt.Printf("Client VM   : %s\n", resp.ClientVM)
	fmt.Printf("Destination : %s\n", resp.Destination)
	fmt.Printf("Success     : %v\n", resp.Success)

	if resp.Success {
		fmt.Printf("Relay RTT   : %.3f ms\n", resp.RTTMS)
		fmt.Printf("TCP elapsed : %.3f ms\n", float64(elapsed.Microseconds())/1000.0)
		fmt.Printf("Payload     : %s\n", string(resp.Payload))
		fmt.Println("Status      : PING SUCCESS")
	} else {
		fmt.Printf("Error       : %s\n", resp.Error)
		fmt.Println("Status      : PING FAILED")
	}

	fmt.Println("========================================")
}
