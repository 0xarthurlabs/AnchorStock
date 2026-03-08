# AnchorStock Backend

Go 后端服务：价格中继器（Relayer）、Oracle 消费者、OHLCV 消费者、清算机器人（Liquidation Bot）、历史 K 线回填（Backfill）。

**说明**：当前仅支持**单只股票**的现货借贷与永续（一套合约对应一只 RWA，如 NVDA）。设计上的重要注意事项（交易时间陷阱、精度、前端状态、清算奖励）见项目根目录 **注意事项.md**。用户要能「存入 RWA」必须先由 RWA owner 执行 **MintRWA** 铸造 RWA 到用户地址，否则流程无法开始（见下方「MintRWA」与主 README 合约部署小节）。

## 服务架构

### 1. Price Relayer（生产者）
- 从 API 抓取美股价格，**仅**推送至 Kafka；不写 DB、不更新链上（由下游消费者负责）。
- **若不配置** `STOCK_API_KEY` 或 `STOCK_API_URL`，则使用 **mock 价格**（本地/测试可用）。`RELAYER_FETCH_INTERVAL` 为抓价间隔（默认 5m，Alpha Vantage 限频建议 5m 或更大）。

### 2. Oracle Consumer（消费者）
- 订阅 Kafka `stock-prices`，按间隔（默认 30s）批量更新链上 Oracle

### 3. OHLCV Consumer（消费者）
- 订阅 Kafka `stock-prices`，将每条价格写入 TimescaleDB `stock_prices` 表（原始 1 分钟粒度）
- **TimescaleDB Continuous Aggregates**：自动物化 1m/5m/15m/1h/4h/1d 视图，API `/api/ohlcv` 直接查物化视图，无需应用层复杂聚合

### 4. Liquidation Bot
- 监控链上活跃仓位 Health Factor，&lt; 1.0 时触发清算
- **可选**：配置 `KAFKA_BROKER` 与 `KAFKA_TOPIC_PRICE` 时，会额外监听 Kafka 价格；每收到价格防抖触发一次清算检查（最多每 5s 一次），便于价格剧烈波动时更快反应

### 5. Backfill（历史 K 线回填）
- 从 Alpha Vantage 拉取历史 K 线（1min/5min/15min/30min/60min/daily），写入 TimescaleDB
- 用于上线前或补全历史，供前端 K 线图使用

## 合约行为说明（与后端/前端联调时参考）

- **LendingPool**：支持**多次借款**（`borrowUSD` 可多次调用，本金累加）和**部分还款**（`repayUSD` 可还任意金额 ≤ 总债务，先抵利息再抵本金）。利息按「当前总本金 × 从**首次借款**时间戳至今」线性计息，不是每笔借款单独计息；还清后再次借款会重置计息起点。
- **MintRWA**：RWA 由 USStockRWA 的 owner 铸造。部署完成后，需用 `contracts/script/MintRWA.s.sol` 给测试用户铸造 RWA（设置 `RWA_TOKEN`、`MINT_TO`、可选 `MINT_AMOUNT`），否则用户无法 depositRWA，借贷/永续流程无法开始。

- **Go**: 1.21+
- **Fiber**: Web 框架
- **Kafka**: 消息队列（confluent-kafka-go）
- **TimescaleDB**: 时序数据库（pgx）；OHLCV 使用 Hypertable + Continuous Aggregates（只存 1 分钟原始数据，自动生成 5m/1h/1d 等视图）
- **Redis**: 缓存（go-redis）。API 服务会用 Redis 缓存「最新价」与「OHLCV 查询」以减轻 DB 压力；未配置或连接失败时自动跳过缓存。
- **Ethereum**: 链上交互（go-ethereum）

## 环境变量

创建 `.env` 文件：

```env
# Blockchain
RPC_URL=http://localhost:8545
PRIVATE_KEY=your_private_key_here
ORACLE_CONTRACT_ADDRESS=0x...
LENDING_POOL_CONTRACT_ADDRESS=0x...
PERP_ENGINE_CONTRACT_ADDRESS=0x...

# Kafka（Relayer 在宿主机运行时必须用 localhost:9092）
KAFKA_BROKER=localhost:9092
KAFKA_TOPIC_PRICE=stock-prices
# 可选：Oracle / OHLCV / 清算 消费者组、Oracle 批量间隔
# KAFKA_CONSUMER_GROUP_ORACLE=oracle-updater
# KAFKA_CONSUMER_GROUP_OHLCV=ohlcv-writer
# KAFKA_CONSUMER_GROUP_LIQUIDATION=liquidation-bot
# ORACLE_CONSUMER_BATCH_INTERVAL=30s

# TimescaleDB
DB_HOST=localhost
DB_PORT=5432
DB_USER=anchorstock
DB_PASSWORD=anchorstock
DB_NAME=anchorstock

# Redis
REDIS_HOST=localhost
REDIS_PORT=6379
# REDIS_PASSWORD=  # 可选 / optional

# API（Relayer / Backfill 用）
# 若不配置 STOCK_API_KEY 或 STOCK_API_URL，Relayer 与 Backfill 将使用 mock 价格（本地/测试可用）
STOCK_API_KEY=your_api_key_here
STOCK_API_URL=https://www.alphavantage.co/query
# RELAYER_FETCH_INTERVAL：Relayer 抓价间隔，默认 5m。Alpha Vantage 免费 5 次/分钟，建议 5m 或更大以免限频
RELAYER_FETCH_INTERVAL=5m
# API 服务监听端口，默认 3001（前端 NEXT_PUBLIC_BACKEND_API_URL 需与此一致）
# API_PORT=3001
```

## 运行

**Kafka 发布失败时请检查：**

1. **先启动 Kafka**：`cd docker && docker-compose up -d zookeeper kafka`（或 `docker-compose up -d`）。
2. **Relayer 在宿主机运行时**：在 `backend/.env` 中必须设置 **`KAFKA_BROKER=localhost:9092`**，不要用 `kafka:9092`。`kafka` 是 Docker 内部服务名，只在容器内可解析，宿主机上会报 `lookup kafka: no such host` 或 `Unknown Topic Or Partition`（因 topic 建在 controller 上，controller 不可达则建不了 topic）。
3. 确认本机 9092 已开放：`Test-NetConnection -ComputerName localhost -Port 9092`（PowerShell）或 `telnet localhost 9092`。

```bash
# 启动基础设施（Kafka, TimescaleDB, Redis）
cd docker
docker-compose up -d

# 运行 Relayer（仅抓价 → Kafka）
go run cmd/relayer/main.go

# 运行 Oracle 消费者（Kafka → 链上 Oracle）
go run cmd/oracle-consumer/main.go

# 运行 OHLCV 消费者（Kafka → TimescaleDB，供 /api/ohlcv 查询）
go run cmd/ohlcv-consumer/main.go

# 启动清算机器人（可选配置 Kafka 后监听价格并防抖触发清算检查）
go run cmd/liquidation-bot/main.go

# 历史 K 线回填（需 STOCK_API_KEY / Alpha Vantage）
go run cmd/backfill/main.go --symbol=NVDA --interval=5min
# 或环境变量：BACKFILL_SYMBOL=NVDA BACKFILL_INTERVAL=5min BACKFILL_START=2024-01-01 BACKFILL_END=2024-12-31 go run cmd/backfill/main.go

# API 服务默认端口 3001（可通过 API_PORT 修改）
curl http://localhost:3001/health

# 清算机器人健康/指标/状态（默认端口 8080）
curl http://localhost:8080/health
curl http://localhost:8080/metrics
curl http://localhost:8080/status
```

## 故障排查

### 为什么 NVDA 在库里只有一条数据，而 TSLA/AAPL 正常更新？

常见原因：

1. **NVDA 只做过「日线」回填**  
   - 若只跑过 `backfill --symbol=NVDA --interval=daily`（或 `1d`），会按**天**写入，每天一条，且时间为当天 00:00 UTC（如 `2026-03-06 00:00:00`）。  
   - 若只回填了很少几天，表里就只会看到很少几条 NVDA；若只跑过一天，就只会有一条。

2. **Relayer / OHLCV Consumer 没常驻**  
   - 实时 K 线依赖：**Relayer** 按间隔抓价并写入 Kafka，**OHLCV Consumer** 消费 Kafka 写入 `stock_prices`。  
   - 若这两个服务没一直跑，NVDA（以及其它标的）都不会有新的分钟级数据，表里就只会是历史回填的那几条。

3. **TSLA/AAPL 数据多是因为**  
   - 要么对它们做过 **intraday 回填**（如 `--interval=1h` 或 `5min`），历史就很多条；  
   - 要么 Relayer + OHLCV Consumer 在跑，持续写入新点。

**处理步骤：**

- **给 NVDA 补足 K 线历史（和 1h 图一致）**  
  用 **1h** 回填一段日期（例如最近几个月），例如：
  ```bash
  go run cmd/backfill/main.go --symbol=NVDA --interval=60min --start=2025-09-01 --end=2026-03-08
  ```
  这样 `ohlcv_1h` 等视图里 NVDA 会有多根 K 线。  
  若希望更细，可用 `--interval=5min`（注意 Alpha Vantage 限频，数据量大时可能要多跑几次或缩小范围）。

- **保证实时数据持续写入**  
  同时运行 **Relayer** 和 **OHLCV Consumer**，并保持运行：
  ```bash
  go run cmd/relayer/main.go
  go run cmd/ohlcv-consumer/main.go
  ```
  这样 NVDA、TSLA、AAPL 等配置的 symbol 都会按间隔写入 `stock_prices`，各标的表现会一致。

**为什么 NVDA 只有一条且不累加（已修复）：**  
Relayer 用 Alpha Vantage 实时报价时，之前把 `LatestTradingDay`（仅日期，如 2026-03-06）当作写入 DB 的时间戳，同一天内每次写入都是同一行，`ON CONFLICT DO UPDATE` 会不断覆盖，所以 NVDA 看起来只有一条。TSLA/AAPL 常因 API 限频走 mock，mock 用 `time.Now()`，所以会多条。代码已改为**一律用当前时间**写入，Relayer 跑起来后 NVDA 会像其他 symbol 一样按间隔累加新行。

**Backfill 报错 "no time series in response"：**  
Alpha Vantage 免费 tier 可能不支持部分历史接口（如 60min 全量），可改用 `--interval=5min` 或缩短日期范围重试；或不做 backfill，只靠 Relayer + OHLCV Consumer 常驻，修复后 NVDA 会随时间自然累加。

**MintRWA（用户获得 RWA）：**  
部署合约后，RWA 余额为 0 的用户无法存入。需由 USStockRWA 的 owner 执行铸造，例如：
```bash
cd contracts
# .env 中：PRIVATE_KEY（须为 RWA owner）、RWA_TOKEN=、MINT_TO=、可选 MINT_AMOUNT
forge script script/MintRWA.s.sol:MintRWA --rpc-url <RPC_URL> --broadcast
```

```bash
# 获取指标（清算机器人，端口 8080）
curl http://localhost:8080/metrics

# 获取状态
curl http://localhost:8080/status
```
