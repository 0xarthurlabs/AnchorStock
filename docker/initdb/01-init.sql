-- TimescaleDB 初始化脚本 / TimescaleDB initialization script
-- 这个脚本会在数据库首次启动时自动执行 / This script will be automatically executed when the database first starts

-- 启用 TimescaleDB 扩展 / Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- 创建股票价格表（如果不存在）/ Create stock prices table (if not exists)
CREATE TABLE IF NOT EXISTS stock_prices (
    time TIMESTAMPTZ NOT NULL,
    symbol VARCHAR(10) NOT NULL,
    price DOUBLE PRECISION NOT NULL,
    volume BIGINT NOT NULL,
    PRIMARY KEY (time, symbol)
);

-- 将表转换为超表（TimescaleDB 特性）/ Convert table to hypertable (TimescaleDB feature)
-- 注意：如果已经是超表，这个命令会失败，但我们可以忽略错误 / Note: If already a hypertable, this will fail, but we can ignore the error
SELECT create_hypertable('stock_prices', 'time', if_not_exists => TRUE);

-- 创建索引以提高查询性能 / Create index for better query performance
CREATE INDEX IF NOT EXISTS idx_stock_prices_symbol_time 
ON stock_prices (symbol, time DESC);

-- 创建复合索引用于常见查询 / Create composite index for common queries
CREATE INDEX IF NOT EXISTS idx_stock_prices_symbol_time_price 
ON stock_prices (symbol, time DESC, price);

-- 输出初始化完成信息 / Output initialization completion message
DO $$
BEGIN
    RAISE NOTICE 'TimescaleDB initialization completed successfully!';
    RAISE NOTICE 'Hypertable stock_prices created with time partitioning.';
END $$;
