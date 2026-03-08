# AnchorStock（美股 RWA 借贷与永续）

基于**单只美股** RWA 的 DeFi 应用：**现货**（借贷）与**永续**（多空）。存入 RWA 作为抵押借出 USD（LendingPool），或使用 aToken 作为保证金开多/空永续仓位（PerpEngine）。**当前仅支持单只股票单部署**（例如一套 LendingPool/PerpEngine/Oracle 对应一只 RWA 如 NVDA）。后端提供价格中继（API → Kafka）、链上 Oracle 更新、K 线存储（TimescaleDB）、价格/K 线 REST API 以及清算机器人。

---

## 1. 系统截图

| 说明 | 截图 |
|------|------|
| 借贷：存入、借款、提取、还款 | ![借贷](assets/lending.png) |
| 永续：开仓/平仓、追加/提取保证金 | ![永续](assets/perp.png) |

---

## 2. 技术架构

### 2.1 整体拓扑

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Frontend (Next.js + Wagmi)                                                      │
│  / → Oracle 状态、K 线图、借贷（存入/借款/提取/还款）、永续                        │
└───────────────┬─────────────────────────────────────────────────────────────────┘
                │ REST /api/price、/api/ohlcv      │ 合约读/写 (Wagmi)
                ▼                                  ▼
┌───────────────────────────────┐    ┌───────────────────────────────────────────────┐
│  cmd/api-server (Fiber :3001)  │    │  EVM 链 (LendingPool、PerpEngine、Oracle)      │
│  GET /api/price/:symbol        │    │  RWA / USD / aToken 合约                       │
│  GET /api/ohlcv?symbol=...    │    └───────────────────────────────────────────────┘
└───────────────┬───────────────┘
                │ 读取
                ▼
┌───────────────────────────────┐     Kafka (stock-prices)
│  TimescaleDB / Redis           │              ▲
└───────────────────────────────┘              │ 发布
┌───────────────────────────────┐              │
│  cmd/relayer                 │──────────────┘
│  股票 API → Kafka             │
└───────────────────────────────┘

┌───────────────────────────────┐    ┌───────────────────────────────┐
│  cmd/oracle-consumer         │    │  cmd/ohlcv-consumer            │
│  Kafka → 批量更新链上 Oracle   │    │  Kafka → TimescaleDB (OHLCV)   │
└───────────────────────────────┘    └───────────────┬───────────────┘
                │                                    │
                ▼                                    ▼
┌───────────────────────────────┐    ┌───────────────────────────────┐
│  StockOracle（链上）           │    │  TimescaleDB (stock_prices)    │
└───────────────────────────────┘    └───────────────────────────────┘

┌───────────────────────────────┐
│  cmd/liquidation-bot         │
│  健康因子 < 1 → 清算            │
└───────────────────────────────┘
```

### 2.2 核心模块

| 模块 | 说明 |
|--------|-------------|
| **合约** | LendingPool（存入 RWA→aToken、借 USD、70% LTV、健康因子）、PerpEngine（aToken 保证金、多空、盈亏、资金费率）、StockOracle（价格源）、USStockRWA、MockUSD、aToken |
| **Relayer** | 从 API（如 Alpha Vantage）拉取股价，发布到 Kafka `stock-prices`；不写 DB、不写链 |
| **Oracle Consumer** | 消费 Kafka，按间隔批量调用链上 Oracle `updatePrices`（如 30s） |
| **OHLCV Consumer** | 消费 Kafka，将每条价格写入 TimescaleDB `stock_prices`；连续聚合 1m/5m/1h/1d |
| **API Server** | 提供 `/api/price/:symbol`、`/api/ohlcv`（来自 TimescaleDB/Redis）、`/api/price-source/:symbol`（诊断） |
| **Liquidation Bot** | 发现 LendingPool / PerpEngine 中有仓位的用户，检查健康因子；&lt; 1.0 时提交清算交易；可选监听 Kafka 以更快响应 |
| **Backfill** | 从 Alpha Vantage 拉取历史 OHLCV 写入 TimescaleDB，供 K 线历史使用 |

### 2.3 数据存储（K 线与最新价）

- **TimescaleDB**：K 线数据使用 **分区存储**（Hypertable 按时间分区），便于时序写入与按时间范围查询；并通过 Continuous Aggregates 物化 1m/5m/1h/1d 等粒度，API `/api/ohlcv` 直接查询物化视图。
- **Redis**：用于缓存最新价与 OHLCV 查询结果，减轻数据库压力；未配置或连接失败时 API 会跳过缓存直接查 DB。

---

## 3. 价格流（链下 → 链上）

合约从 Oracle 读价，因此价格必须由链下推上链。

1. **Relayer**（周期）：股票 API → Kafka 主题 `stock-prices`。
2. **Oracle Consumer**：消费 Kafka，按间隔（如 30s）批量调用 `StockOracle.updatePrices(symbols, prices, timestamps)`。
3. **LendingPool / PerpEngine**：通过 `oracle.getPrice(symbol)` 获取抵押价值、标记价与健康因子。

---

## 4. 借贷与永续合约行为

- **LendingPool**
  - 存入 RWA：用户对池子授权 RWA 后调用 `depositRWA(amount)`；池子按 1:1 铸造 aToken 给用户。
  - 借 USD：上限为「存款 × 价格 × LTV」减去当前债务；利息从首次借款时间戳起线性计息。
  - 支持多次借款与部分还款；还款先抵利息再抵本金。债务还清后再次借款会重置计息起点。
- **PerpEngine**
  - 保证金为 **aToken**（在 LendingPool 存入 RWA 获得）。用户对 PerpEngine 授权 aToken 后，以仓位大小和保证金数量开多/空。
  - 盈亏与健康因子依赖 Oracle 价格；价格过期（如休市）会 revert（Market Hours Trap）。
- **单标的单部署**：当前设计为每次部署对应一只 RWA（如 NVDA）；多标的需多次部署或改合约。

---

## 4.1 重要说明（TradFi 与 DeFi 差异）

- **交易时间陷阱（Market Hours Trap）**：加密货币 24/7 交易，美股周末与盘后休市。若周末出现重大利空，链下价格已跌而链上预言机价格停滞，借贷与永续仓位无法被清算；周一开盘跳空可能导致系统瞬间巨额坏账。合约会检测价格过期（如 Market Hours Trap）并可能 revert；README 中明确写出这一 TradFi/DeFi 时间错配。

---

## 5. 代码结构

### 5.1 仓库目录

```
AnchorStock/
├── backend/
│   ├── cmd/
│   │   ├── api-server/     # HTTP API（价格、OHLCV）
│   │   ├── relayer/        # 股票 API → Kafka
│   │   ├── oracle-consumer/# Kafka → 链上 Oracle updatePrices
│   │   ├── ohlcv-consumer/ # Kafka → TimescaleDB
│   │   ├── liquidation-bot/# 健康检查 + 清算
│   │   └── backfill/       # 历史 OHLCV → DB
│   ├── internal/
│   │   ├── config/         # 基于环境变量的配置
│   │   ├── relayer/        # 拉价 + Kafka 发布
│   │   ├── kafka/          # Producer、Consumer
│   │   ├── blockchain/     # Oracle 客户端、合约客户端
│   │   ├── database/       # TimescaleDB（表结构、插入、OHLCV 视图）
│   │   ├── cache/          # Redis
│   │   ├── liquidation/    # 机器人、仓位发现、健康检查、交易监听
│   │   └── ...
│   └── pkg/
│       └── price/          # StockPrice、fetcher（API/模拟）、历史
├── contracts/
│   ├── src/
│   │   ├── LendingPool.sol
│   │   ├── PerpEngine.sol
│   │   ├── StockOracle.sol
│   │   ├── tokens/         # USStockRWA、MockUSD、aToken
│   │   ├── mocks/          # MockPyth
│   │   └── libraries/
│   ├── script/
│   │   ├── Deploy.s.sol
│   │   ├── MintRWA.s.sol
│   │   └── Verify.s.sol
│   └── test/
├── frontend/
│   └── app/
│       ├── page.tsx        # 主页：标的选择、K 线、借贷/永续标签
│       ├── components/     # LendingPanel、PerpPanel、KLineChart、OracleStatus、Header
│       ├── lib/            # contracts.ts、wagmi 配置
│       └── types/
├── docker/
│   ├── docker-compose.yml  # Zookeeper、Kafka、TimescaleDB、Redis、Kafka UI、Redis Commander
│   └── initdb/             # TimescaleDB 初始化（hypertable、连续聚合）
├── README.md
└── README_zh.md
```

### 5.2 关键流程

- **价格链路**：Relayer → Kafka → Oracle Consumer → 链上；同一 Kafka → OHLCV Consumer → TimescaleDB。
- **前端**：连接钱包（Wagmi），读取 LendingPool（存款、借款、健康因子）、PerpEngine（仓位）、Oracle（价格）；请求后端最新价与 OHLCV；用户操作（存入、借款、还款、开平仓）通过 `writeContract` / `writeContractAsync`。
- **清算**：机器人从事件或配置发现活跃用户，检查 LendingPool 与 PerpEngine 健康因子，在 HF &lt; 1.0 时提交 `liquidate` / 永续清算；清算人有 **5% 奖励**。

---

## 6. 开发环境

### 6.1 依赖

- **Go** 1.21+（后端）
- **Node.js** 18+（前端）
- **Foundry**（合约：forge、anvil、cast）
- **Docker / Docker Compose**（Kafka、TimescaleDB、Redis）

### 6.2 克隆与配置

```bash
git clone https://github.com/0xarthurlabs/AnchorStock
cd AnchorStock
```

### 6.3 启动基础设施（Docker）

```bash
cd docker
docker-compose up -d
```

- **Kafka** `localhost:9092`（宿主机）；宿主机上的 Relayer 需设置 `KAFKA_BROKER=localhost:9092`
- **TimescaleDB** `localhost:5432`（用户/密码/库：anchorstock）
- **Redis** `localhost:6379`
- **Kafka UI** `localhost:8082`，**Redis Commander** `localhost:8081`

### 6.4 后端

在 `backend/.env` 中配置（完整项见 backend README），至少包含：

- `RPC_URL`、`PRIVATE_KEY`（Oracle Consumer / 清算用；Relayer 不需链）
- `KAFKA_BROKER=localhost:9092`、`KAFKA_TOPIC_PRICE=stock-prices`
- `DB_*`（TimescaleDB），`REDIS_*` 可选
- `STOCK_API_KEY`、`STOCK_API_URL`（Relayer / Backfill 用，如 Alpha Vantage）；**若不配置则使用 mock 价格**（本地/测试可用）。`RELAYER_FETCH_INTERVAL` 为 Relayer 抓价间隔（默认 5m，Alpha Vantage 限频建议 5m 或更大）。

```bash
# 终端 1：Relayer（API → Kafka）
go run backend/cmd/relayer/main.go

# 终端 2：Oracle Consumer（Kafka → 链上）
go run backend/cmd/oracle-consumer/main.go

# 终端 3：OHLCV Consumer（Kafka → TimescaleDB）
go run backend/cmd/ohlcv-consumer/main.go

# 终端 4：API 服务（价格 + OHLCV 接口）
go run backend/cmd/api-server/main.go

# 可选：清算机器人
go run backend/cmd/liquidation-bot/main.go

# 可选：K 线历史回填
go run backend/cmd/backfill/main.go --symbol=NVDA --interval=5min
```

### 6.5 合约

在 `contracts/.env` 中配置 `PRIVATE_KEY`（可选 `ETH_RPC_URL`）。部署（本地 Anvil 或测试网）：

```bash
cd contracts
forge build
# 本地
forge script script/Deploy.s.sol:DeployScript --rpc-url http://localhost:8545 --broadcast
# 测试网示例
forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC_URL> --broadcast --chain-id <CHAIN_ID> --gas-estimate-multiplier 150
```

将部署得到的地址（LendingPool、PerpEngine、Oracle、RWA_TOKEN、USD_TOKEN、aToken）填入前端环境变量。

**MintRWA（用户能存入前的必要步骤）**：RWA 仅由 USStockRWA 的 owner 铸造。部署后，部署者（owner）必须给用户地址铸造 RWA，否则用户 RWA 余额为 0，无法调用 `depositRWA`。使用 MintRWA 脚本：

```bash
# 在 contracts/.env 中设置：PRIVATE_KEY、RWA_TOKEN=<USStockRWA 地址>、MINT_TO=<用户地址>，可选 MINT_AMOUNT（默认 1000 表示 1000e18）
forge script script/MintRWA.s.sol:MintRWA --rpc-url <RPC_URL> --broadcast
```

不做这一步，借贷/永续流程无法开始（没有 RWA 可存）。

### 6.6 前端

创建 `frontend/.env.local`：

```env
NEXT_PUBLIC_BACKEND_API_URL=http://localhost:3001
NEXT_PUBLIC_ORACLE_CONTRACT_ADDRESS=0x...
NEXT_PUBLIC_LENDING_POOL_CONTRACT_ADDRESS=0x...
NEXT_PUBLIC_PERP_ENGINE_CONTRACT_ADDRESS=0x...
NEXT_PUBLIC_RWA_TOKEN_CONTRACT_ADDRESS=0x...
NEXT_PUBLIC_USD_TOKEN_CONTRACT_ADDRESS=0x...
NEXT_PUBLIC_A_TOKEN_CONTRACT_ADDRESS=0x...
NEXT_PUBLIC_CHAIN_ID=1328
```

```bash
cd frontend
npm install
npm run dev
```

前端通过 `NEXT_PUBLIC_BACKEND_API_URL` 请求 `/api/price/:symbol` 与 `/api/ohlcv`；合约调用走 Wagmi 配置的链。

### 6.7 配置摘要

| 组件 | 主要配置 |
|-----------|------------|
| 后端 | `RPC_URL`、`PRIVATE_KEY`、`KAFKA_BROKER`、`KAFKA_TOPIC_PRICE`、`DB_*`、`STOCK_API_KEY`（可选，不配则 mock 价）、`STOCK_API_URL`、`RELAYER_FETCH_INTERVAL`（抓价间隔，默认 5m）、`ORACLE_CONTRACT_ADDRESS`、`LENDING_POOL_*`、`PERP_ENGINE_*` |
| 前端 | `NEXT_PUBLIC_BACKEND_API_URL`、各 `NEXT_PUBLIC_*_CONTRACT_ADDRESS`、`NEXT_PUBLIC_CHAIN_ID` |
| 合约 | `contracts/.env` 中的 `PRIVATE_KEY` |

---

## 7. API 参考

### 7.1 后端 API（cmd/api-server）

- `GET /health` — 健康检查
- `GET /api/price/:symbol` — 指定标的最新价（如 NVDA）；来自 Redis 或 DB
- `GET /api/ohlcv?symbol=NVDA&interval=1h&limit=100` — K 线 OHLCV；interval 可为 1m、5m、15m、1h、4h、1d
- `GET /api/price-source/:symbol` — 诊断：数据来自 API 还是 mock、限频信息

默认端口：3001（可通过环境变量修改）。

### 7.2 清算机器人

- `GET /health` — 健康检查
- `GET /metrics` — 指标
- `GET /status` — 状态

---

## 8. 许可证

本项目采用 **GPL-3.0** 许可证。完整文本见仓库。
