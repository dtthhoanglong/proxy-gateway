package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/florianl/go-nfqueue/v2"
	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

const queueNum = 100

func main() {
	log.Printf("ICMP NFQUEUE daemon starting")
	log.Printf("NFQUEUE number: %d", queueNum)

	config := nfqueue.Config{
		NfQueue:      queueNum,
		MaxPacketLen: 0xFFFF,
		MaxQueueLen:  0xFF,
		Copymode:     nfqueue.NfQnlCopyPacket,
		WriteTimeout: 15 * time.Millisecond,
	}

	nf, err := nfqueue.Open(&config)
	if err != nil {
		log.Fatalf("open NFQUEUE failed: %v", err)
	}
	defer nf.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle Ctrl+C / SIGTERM.
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Printf("shutdown signal received")
		cancel()
	}()

	fn := func(attr nfqueue.Attribute) int {
		if attr.PacketID == nil {
			log.Printf("packet received without packet ID")
			return 0
		}

		packetID := *attr.PacketID

		if attr.Payload == nil {
			log.Printf("[%d] packet has no payload", packetID)

			if err := nf.SetVerdict(packetID, nfqueue.NfAccept); err != nil {
				log.Printf("[%d] set ACCEPT verdict failed: %v", packetID, err)
			}

			return 0
		}

		packet := gopacket.NewPacket(
			*attr.Payload,
			layers.LayerTypeIPv4,
			gopacket.Default,
		)

		ipLayer := packet.Layer(layers.LayerTypeIPv4)
		icmpLayer := packet.Layer(layers.LayerTypeICMPv4)

		if ipLayer != nil && icmpLayer != nil {
			ip := ipLayer.(*layers.IPv4)
			icmp := icmpLayer.(*layers.ICMPv4)

			log.Printf(
				"[%d] ICMP %s -> %s type=%d code=%d id=%d seq=%d len=%d",
				packetID,
				ip.SrcIP,
				ip.DstIP,
				icmp.TypeCode.Type(),
				icmp.TypeCode.Code(),
				icmp.Id,
				icmp.Seq,
				len(*attr.Payload),
			)
		} else {
			log.Printf(
				"[%d] packet received len=%d (not parsed as IPv4/ICMP)",
				packetID,
				len(*attr.Payload),
			)
		}

		// Test daemon: always allow the packet to continue.
		if err := nf.SetVerdict(packetID, nfqueue.NfAccept); err != nil {
			log.Printf("[%d] set ACCEPT verdict failed: %v", packetID, err)
		}

		return 0
	}

	if err := nf.RegisterWithErrorFunc(ctx, fn, func(err error) int {
		log.Printf("NFQUEUE error: %v", err)
		return 0
	}); err != nil {
		log.Fatalf("register NFQUEUE callback failed: %v", err)
	}

	log.Printf("ICMP NFQUEUE daemon listening on queue %d", queueNum)

	<-ctx.Done()

	log.Printf("ICMP NFQUEUE daemon stopped")
}