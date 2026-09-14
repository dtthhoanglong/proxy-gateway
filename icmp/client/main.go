package main

import (
	"fmt"
	"github.com/dtthhoanglong/proxy-gateway/icmp/client/relayclient"
	"github.com/dtthhoanglong/proxy-gateway/icmp/protocol"
	"log"
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

	client := relayclient.New(relayAddr)
	defer client.Close()

	start := time.Now()

	resp, err := client.PingWithRetry(req)
	if err != nil {
		log.Fatalf("ICMP relay request failed: %v", err)
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
