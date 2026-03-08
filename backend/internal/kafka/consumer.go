package kafka

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/segmentio/kafka-go"
	"anchorstock-backend/pkg/price"
)

// Consumer Kafka 消费者 / Kafka consumer
type Consumer struct {
	reader *kafka.Reader
	topic  string
}

// NewConsumer 创建 Kafka 消费者 / Create Kafka consumer
func NewConsumer(broker, topic, groupID string) (*Consumer, error) {
	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers:  []string{broker},
		Topic:    topic,
		GroupID:  groupID,
		MinBytes: 10e3, // 10KB
		MaxBytes: 10e6, // 10MB
		// 从最早的消息开始消费 / Start from earliest messages
		StartOffset: kafka.FirstOffset,
		// 自动提交偏移量 / Auto commit offsets
		CommitInterval: time.Second,
	})

	return &Consumer{
		reader: reader,
		topic:  topic,
	}, nil
}

// Consume 消费消息（阻塞式）/ Consume messages (blocking)
// handler 函数处理每条消息 / handler function processes each message
func (c *Consumer) Consume(handler func(*price.StockPrice) error) error {
	return c.ConsumeWithContext(context.Background(), handler)
}

// ConsumeWithContext 使用可取消的 context 消费消息 / Consume with cancellable context
func (c *Consumer) ConsumeWithContext(ctx context.Context, handler func(*price.StockPrice) error) error {
	log.Printf("Starting to consume messages from topic: %s\n", c.topic)

	for {
		// 读取消息 / Read message
		msg, err := c.reader.ReadMessage(ctx)
		if err != nil {
			// 检查是否是上下文取消 / Check if context is cancelled
			if err == context.Canceled {
				log.Println("Consumer context cancelled, stopping...")
				return nil
			}
			return fmt.Errorf("error reading message: %w", err)
		}

		// 解析价格数据 / Parse price data
		priceData, err := price.FromJSON(msg.Value)
		if err != nil {
			log.Printf("Error parsing price data: %v\n", err)
			// 继续处理下一条消息 / Continue processing next message
			continue
		}

		// 处理消息 / Process message
		if err := handler(priceData); err != nil {
			log.Printf("Error handling price for %s: %v\n", priceData.Symbol, err)
			// 继续处理下一条消息 / Continue processing next message
		}
	}
}

// Close 关闭消费者 / Close consumer
func (c *Consumer) Close() error {
	if c.reader != nil {
		return c.reader.Close()
	}
	return nil
}
