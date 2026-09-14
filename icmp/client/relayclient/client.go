package relayclient

import (
	"encoding/json"
	"fmt"
	"github.com/dtthhoanglong/proxy-gateway/icmp/protocol"
	"net"
	"sync"
	"time"
)

type Client struct {
	RelayAddr string
	mu        sync.Mutex
	conn      net.Conn
}

func New(relayAddr string) *Client {
	return &Client{
		RelayAddr: relayAddr,
	}
}
func (c *Client) connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		return nil
	}

	conn, err := net.DialTimeout("tcp", c.RelayAddr, 5*time.Second)
	if err != nil {
		return fmt.Errorf("connect to relay failed: %w", err)
	}

	c.conn = conn

	return nil
}
func (c *Client) close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		_ = c.conn.Close()
		c.conn = nil
	}
}
func (c *Client) Ping(req protocol.PingRequest) (protocol.PingResponse, error) {
	if err := c.connect(); err != nil {
		return protocol.PingResponse{}, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		return protocol.PingResponse{}, fmt.Errorf("relay connection is not available")
	}

	if err := c.conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		_ = c.conn.Close()
		c.conn = nil
		return protocol.PingResponse{}, fmt.Errorf("set relay deadline failed: %w", err)
	}

	encoder := json.NewEncoder(c.conn)
	decoder := json.NewDecoder(c.conn)

	if err := encoder.Encode(req); err != nil {
		_ = c.conn.Close()
		c.conn = nil
		return protocol.PingResponse{}, fmt.Errorf("send PING_REQUEST failed: %w", err)
	}

	var resp protocol.PingResponse

	if err := decoder.Decode(&resp); err != nil {
		_ = c.conn.Close()
		c.conn = nil
		return protocol.PingResponse{}, fmt.Errorf("receive PING_RESPONSE failed: %w", err)
	}

	return resp, nil
}
func (c *Client) PingWithRetry(req protocol.PingRequest) (protocol.PingResponse, error) {
	resp, err := c.Ping(req)
	if err == nil {
		return resp, nil
	}
	c.close()

	time.Sleep(500 * time.Millisecond)

	return c.Ping(req)
}
func (c *Client) Close() {
	c.close()
}
