// Type definitions for AnchorStock frontend

export interface OHLCV {
  time: number; // Unix timestamp
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}

export interface OracleStatus {
  strategy: 'PYTH' | 'CUSTOM_RELAYER';
  isStale: boolean;
  lastUpdate: number;
  price: bigint;
}

export interface UserStatus {
  balance: bigint;
  healthFactor: bigint;
  liquidationPrice: bigint;
}

export interface Position {
  side: 'LONG' | 'SHORT';
  size: bigint;
  entryPrice: bigint;
  collateral: bigint;
  pnl: bigint;
  healthFactor: bigint;
}
