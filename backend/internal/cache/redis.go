// Package cache 提供 Redis 缓存封装，供 API 层缓存最新价、OHLCV 等。
package cache

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

// Cache Redis 缓存客户端（可选：连接失败时返回 nil，调用方不缓存）
type Cache struct {
	client *redis.Client
}

// New 创建 Redis 缓存。若 host 为空或连接失败，返回 (nil, nil)，调用方可不使用缓存。
func New(host, port, password string) (*Cache, error) {
	if host == "" && port == "" {
		return nil, nil
	}
	addr := fmt.Sprintf("%s:%s", host, port)
	if port == "" {
		addr = host
	}
	opt := &redis.Options{
		Addr:     addr,
		Password: password,
		DB:       0,
	}
	client := redis.NewClient(opt)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	err := client.Ping(ctx).Err()
	cancel()
	if err != nil {
		log.Printf("Redis connection failed (cache disabled): %v", err)
		client.Close()
		return nil, nil
	}
	log.Println("Redis cache connected")
	return &Cache{client: client}, nil
}

// Get 获取 key，不存在返回 redis.Nil。
func (c *Cache) Get(ctx context.Context, key string) ([]byte, error) {
	if c == nil || c.client == nil {
		return nil, redis.Nil
	}
	data, err := c.client.Get(ctx, key).Bytes()
	if err == redis.Nil {
		return nil, redis.Nil
	}
	return data, err
}

// Set 写入 key，ttl=0 表示不过期。
func (c *Cache) Set(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	if c == nil || c.client == nil {
		return nil
	}
	return c.client.Set(ctx, key, value, ttl).Err()
}

// Close 关闭连接。
func (c *Cache) Close() error {
	if c == nil || c.client == nil {
		return nil
	}
	return c.client.Close()
}
