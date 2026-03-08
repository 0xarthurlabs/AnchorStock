package kafka

import (
	"context"
	"fmt"
	"log"
	"net"
	"strconv"
	"time"

	"anchorstock-backend/pkg/price"

	"github.com/segmentio/kafka-go"
)

// Producer Kafka 生产者 / Kafka producer
type Producer struct {
	writer *kafka.Writer
	topic  string
}

// ensureTopicExists 确保 topic 存在，不存在则创建（解决 broker 自动建 topic 不可靠的问题）
// 当 Relayer 在宿主机运行、Kafka 在 Docker 时，broker 需用 localhost:9092；controller 可能返回 kafka:9092 导致宿主机无法连接，此处回退到 broker 地址建 topic。
// Ensure topic exists; create if not. When relayer runs on host and Kafka in Docker, use KAFKA_BROKER=localhost:9092; controller may return kafka:9092, so fallback to broker addr for CreateTopics.
func ensureTopicExists(broker, topic string, numPartitions int) error {
	conn, err := kafka.Dial("tcp", broker)
	if err != nil {
		return fmt.Errorf("failed to dial broker: %w", err)
	}
	defer conn.Close()

	controller, err := conn.Controller()
	if err != nil {
		return fmt.Errorf("failed to get controller: %w", err)
	}

	controllerAddr := net.JoinHostPort(controller.Host, strconv.Itoa(controller.Port))
	controllerConn, err := kafka.Dial("tcp", controllerAddr)
	if err != nil {
		// 宿主机连 Docker Kafka 时，controller 常返回 kafka:9092，无法解析；单节点时 broker 即 controller，用 broker 再连一次
		// When host connects to Docker Kafka, controller often returns kafka:9092 which doesn't resolve; use broker as fallback (single node = controller).
		log.Printf("Could not dial controller at %s: %v, trying broker %s for CreateTopics\n", controllerAddr, err, broker)
		controllerConn, err = kafka.Dial("tcp", broker)
		if err != nil {
			return fmt.Errorf("failed to dial controller or broker: %w", err)
		}
	}
	defer controllerConn.Close()

	// CreateTopics is idempotent: existing topic is not an error on Confluent/Kafka 2.4+
	topicConfigs := []kafka.TopicConfig{
		{Topic: topic, NumPartitions: numPartitions, ReplicationFactor: 1},
	}
	err = controllerConn.CreateTopics(topicConfigs...)
	if err != nil {
		return fmt.Errorf("failed to create topic %q: %w", topic, err)
	}
	log.Printf("Kafka topic %q ensured (created or already exists)\n", topic)
	return nil
}

// NewProducer 创建 Kafka 生产者 / Create Kafka producer
func NewProducer(broker, topic string) (*Producer, error) {
	// 先确保 topic 存在，避免 Unknown Topic Or Partition（broker 自动建 topic 与 kafka-go 配合不稳定）
	if err := ensureTopicExists(broker, topic, 3); err != nil {
		log.Printf("Warning: could not ensure topic %q: %v (will try to write anyway)\n", topic, err)
	}

	writer := &kafka.Writer{
		Addr:         kafka.TCP(broker),
		Topic:        topic,
		Balancer:     &kafka.LeastBytes{}, // 使用最少字节负载均衡 / Use least bytes load balancer
		RequiredAcks: kafka.RequireAll,    // 等待所有副本确认 / Wait for all replicas to acknowledge
		Async:        false,               // 同步写入 / Synchronous writes
		BatchSize:    1,                   // 每条消息单独发送 / Send each message individually
		BatchTimeout: 10 * time.Millisecond,
		WriteTimeout: 10 * time.Second,
	}

	return &Producer{
		writer: writer,
		topic:  topic,
	}, nil
}

// PublishPrice 发布价格数据到 Kafka / Publish price data to Kafka
func (p *Producer) PublishPrice(priceData *price.StockPrice) error {
	// 将价格数据序列化为 JSON / Serialize price data to JSON
	value, err := priceData.ToJSON()
	if err != nil {
		return fmt.Errorf("failed to serialize price: %w", err)
	}

	// 使用股票符号作为 key，便于分区 / Use stock symbol as key for partitioning
	key := []byte(priceData.Symbol)

	// 创建消息 / Create message
	message := kafka.Message{
		Key:   key,
		Value: value,
		Headers: []kafka.Header{
			{Key: "symbol", Value: []byte(priceData.Symbol)},
			{Key: "timestamp", Value: []byte(priceData.Timestamp.Format("2006-01-02T15:04:05Z07:00"))},
		},
		Time: priceData.Timestamp,
	}

	// 发送消息 / Send message
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	err = p.writer.WriteMessages(ctx, message)
	if err != nil {
		return fmt.Errorf("failed to write message: %w", err)
	}

	log.Printf("Published price for %s: $%.2f to topic %s\n",
		priceData.Symbol, priceData.Price, p.topic)

	return nil
}

// PublishPrices 批量发布价格数据 / Publish multiple price data
func (p *Producer) PublishPrices(prices map[string]*price.StockPrice) error {
	// 准备批量消息 / Prepare batch messages
	messages := make([]kafka.Message, 0, len(prices))

	for _, priceData := range prices {
		// 将价格数据序列化为 JSON / Serialize price data to JSON
		value, err := priceData.ToJSON()
		if err != nil {
			log.Printf("Error serializing price for %s: %v\n", priceData.Symbol, err)
			continue
		}

		// 使用股票符号作为 key / Use stock symbol as key
		key := []byte(priceData.Symbol)

		message := kafka.Message{
			Key:   key,
			Value: value,
			Headers: []kafka.Header{
				{Key: "symbol", Value: []byte(priceData.Symbol)},
				{Key: "timestamp", Value: []byte(priceData.Timestamp.Format("2006-01-02T15:04:05Z07:00"))},
			},
			Time: priceData.Timestamp,
		}

		messages = append(messages, message)
	}

	// 批量发送消息 / Send messages in batch
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	err := p.writer.WriteMessages(ctx, messages...)
	if err != nil {
		return fmt.Errorf("failed to write messages: %w", err)
	}

	log.Printf("Published %d prices to topic %s\n", len(messages), p.topic)
	return nil
}

// Close 关闭生产者 / Close producer
func (p *Producer) Close() {
	if p.writer != nil {
		if err := p.writer.Close(); err != nil {
			log.Printf("Error closing Kafka writer: %v\n", err)
		}
	}
}
