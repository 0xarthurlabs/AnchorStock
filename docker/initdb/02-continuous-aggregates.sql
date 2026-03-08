-- TimescaleDB Continuous Aggregates：只存 1 分钟粒度原始数据，自动物化 1m/5m/1h/1d OHLCV 视图
-- 依赖 01-init.sql 已创建 stock_prices 超表

-- 1 分钟 K 线（与原始数据同粒度，物化后查询更快）
DO $$
BEGIN
  CREATE MATERIALIZED VIEW ohlcv_1m
  WITH (timescaledb.continuous) AS
  SELECT
    time_bucket('1 minute', time) AS bucket,
    symbol,
    first(price, time) AS open,
    max(price) AS high,
    min(price) AS low,
    last(price, time) AS close,
    sum(volume)::bigint AS volume
  FROM stock_prices
  GROUP BY 1, 2
  WITH NO DATA;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 5 分钟 K 线
DO $$
BEGIN
  CREATE MATERIALIZED VIEW ohlcv_5m
  WITH (timescaledb.continuous) AS
  SELECT
    time_bucket('5 minutes', time) AS bucket,
    symbol,
    first(price, time) AS open,
    max(price) AS high,
    min(price) AS low,
    last(price, time) AS close,
    sum(volume)::bigint AS volume
  FROM stock_prices
  GROUP BY 1, 2
  WITH NO DATA;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 1 小时 K 线
DO $$
BEGIN
  CREATE MATERIALIZED VIEW ohlcv_1h
  WITH (timescaledb.continuous) AS
  SELECT
    time_bucket('1 hour', time) AS bucket,
    symbol,
    first(price, time) AS open,
    max(price) AS high,
    min(price) AS low,
    last(price, time) AS close,
    sum(volume)::bigint AS volume
  FROM stock_prices
  GROUP BY 1, 2
  WITH NO DATA;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 1 天 K 线
DO $$
BEGIN
  CREATE MATERIALIZED VIEW ohlcv_1d
  WITH (timescaledb.continuous) AS
  SELECT
    time_bucket('1 day', time) AS bucket,
    symbol,
    first(price, time) AS open,
    max(price) AS high,
    min(price) AS low,
    last(price, time) AS close,
    sum(volume)::bigint AS volume
  FROM stock_prices
  GROUP BY 1, 2
  WITH NO DATA;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 4 小时 K 线（API 支持 4h）
DO $$
BEGIN
  CREATE MATERIALIZED VIEW ohlcv_4h
  WITH (timescaledb.continuous) AS
  SELECT
    time_bucket('4 hours', time) AS bucket,
    symbol,
    first(price, time) AS open,
    max(price) AS high,
    min(price) AS low,
    last(price, time) AS close,
    sum(volume)::bigint AS volume
  FROM stock_prices
  GROUP BY 1, 2
  WITH NO DATA;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 15 分钟 K 线（API 支持 15m）
DO $$
BEGIN
  CREATE MATERIALIZED VIEW ohlcv_15m
  WITH (timescaledb.continuous) AS
  SELECT
    time_bucket('15 minutes', time) AS bucket,
    symbol,
    first(price, time) AS open,
    max(price) AS high,
    min(price) AS low,
    last(price, time) AS close,
    sum(volume)::bigint AS volume
  FROM stock_prices
  GROUP BY 1, 2
  WITH NO DATA;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 为每个物化视图添加自动刷新策略（若已存在则忽略）
DO $$
BEGIN
  PERFORM add_continuous_aggregate_policy('ohlcv_1m', start_offset => INTERVAL '7 days', end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '1 minute');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM add_continuous_aggregate_policy('ohlcv_5m', start_offset => INTERVAL '30 days', end_offset => INTERVAL '5 minutes', schedule_interval => INTERVAL '5 minutes');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM add_continuous_aggregate_policy('ohlcv_15m', start_offset => INTERVAL '30 days', end_offset => INTERVAL '15 minutes', schedule_interval => INTERVAL '15 minutes');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM add_continuous_aggregate_policy('ohlcv_1h', start_offset => INTERVAL '90 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '1 hour');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM add_continuous_aggregate_policy('ohlcv_4h', start_offset => INTERVAL '180 days', end_offset => INTERVAL '4 hours', schedule_interval => INTERVAL '4 hours');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM add_continuous_aggregate_policy('ohlcv_1d', start_offset => INTERVAL '2 years', end_offset => INTERVAL '1 day', schedule_interval => INTERVAL '1 day');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  RAISE NOTICE 'Continuous aggregates (ohlcv_1m, 5m, 15m, 1h, 4h, 1d) and refresh policies created.';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Policies may already exist: %', SQLERRM;
END $$;
