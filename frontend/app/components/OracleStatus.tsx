'use client';

import { useEffect, useState } from 'react';
import { useReadContract } from 'wagmi';
import { CONTRACTS, ORACLE_ABI } from '../lib/contracts';
import { formatEther } from 'viem';

const BACKEND_API_URL = process.env.NEXT_PUBLIC_BACKEND_API_URL || 'http://localhost:3001';
const DEFAULT_SYMBOL = 'NVDA';

interface BackendPrice {
  price: number;
  symbol: string;
  timestamp: number;
  volume?: number;
}

interface OracleStatusProps {
  /** 当前选中的股票代码，用于 Oracle 与后端价格展示 / Symbol for oracle and backend price */
  symbol?: string;
}

export function OracleStatus({ symbol = DEFAULT_SYMBOL }: OracleStatusProps) {
  const [mounted, setMounted] = useState(false);
  const [backendPrice, setBackendPrice] = useState<BackendPrice | null>(null);

  useEffect(() => {
    setMounted(true);
  }, []);

  // Fetch backend (API) price for the selected symbol
  useEffect(() => {
    const fetchBackendPrice = async () => {
      try {
        const res = await fetch(`${BACKEND_API_URL}/api/price/${symbol}`);
        if (res.ok) {
          const data = await res.json();
          setBackendPrice({
            price: data.price,
            symbol: data.symbol,
            timestamp: data.timestamp,
            volume: data.volume,
          });
        } else {
          setBackendPrice(null);
        }
      } catch {
        setBackendPrice(null);
      }
    };
    fetchBackendPrice();
    const interval = setInterval(fetchBackendPrice, 30000);
    return () => clearInterval(interval);
  }, [symbol]);

  const oracleAddress = (CONTRACTS.ORACLE ??
    '0x0000000000000000000000000000000000000000') as `0x${string}`;
  const enabled = !!CONTRACTS.ORACLE && mounted;

  const { data: strategy } = useReadContract({
    address: oracleAddress,
    abi: ORACLE_ABI,
    functionName: 'oracleStrategy',
    // @ts-expect-error - runtime is fine, TypeScript types may differ
    query: { enabled },
  });

  const { data: priceData } = useReadContract({
    address: oracleAddress,
    abi: ORACLE_ABI,
    functionName: 'getPrice',
    args: [symbol],
    // @ts-expect-error - see above
    query: { enabled },
  });

  const { data: isStale } = useReadContract({
    address: oracleAddress,
    abi: ORACLE_ABI,
    functionName: 'isPriceStale',
    args: [symbol],
    // @ts-expect-error - see above
    query: { enabled },
  });

  // Support both bigint and number from chain (wagmi/viem can return either)
  // 支持链上返回的 bigint 或 number（wagmi/viem 可能返回任一种）
  const strategyNum = strategy !== undefined && strategy !== null ? Number(strategy) : -1;
  const strategyName = strategyNum === 0 ? 'PYTH' : strategyNum === 1 ? 'CUSTOM_RELAYER' : 'UNKNOWN';
  const price = priceData?.[0] as bigint | undefined;
  const timestamp = priceData?.[1] as bigint | undefined;

  const formatPrice = (p: bigint | undefined) => {
    if (!p) return 'N/A';
    return `$${Number(formatEther(p)).toFixed(2)}`;
  };

  const formatTimestampShort = (ts: bigint | undefined) => {
    if (!ts) return 'N/A';
    const date = new Date(Number(ts) * 1000);
    return date.toISOString().replace('T', ' ').substring(0, 16) + ' UTC';
  };

  // Loading skeleton
  if (!mounted) {
    return (
      <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border border-gray-200 dark:border-gray-700 animate-pulse">
        <div className="h-5 bg-gray-200 dark:bg-gray-700 rounded w-1/4 mb-2"></div>
        <div className="space-y-2">
          <div className="h-3.5 bg-gray-200 dark:bg-gray-700 rounded w-1/2"></div>
          <div className="h-3.5 bg-gray-200 dark:bg-gray-700 rounded w-1/2"></div>
          <div className="h-3.5 bg-gray-200 dark:bg-gray-700 rounded w-1/2"></div>
        </div>
      </div>
    );
  }

  // If oracle address is not configured, show a friendly message / 未配置 oracle 地址时显示提示
  if (!CONTRACTS.ORACLE) {
    return (
      <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">Oracle Status</h2>
        <p className="text-sm text-gray-500 dark:text-gray-400">Oracle contract address not configured</p>
      </div>
    );
  }

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg p-4 border border-gray-200 dark:border-gray-700">
      <p className="text-sm text-gray-700 dark:text-gray-300 flex flex-wrap items-center gap-x-1 gap-y-1">
        <span className="font-semibold text-gray-900 dark:text-white">Oracle Status</span>
        <span className="text-gray-400">·</span>
        <span className="text-gray-600 dark:text-gray-400">Strategy:</span>
        <span className="font-medium text-gray-900 dark:text-white">{strategyName}</span>
        <span className="text-gray-400">·</span>
        <span className="text-gray-600 dark:text-gray-400">Chain ({symbol}):</span>
        <span className="font-medium text-gray-900 dark:text-white">{formatPrice(price)}</span>
        <span className="text-gray-500 dark:text-gray-500 text-xs">({formatTimestampShort(timestamp)})</span>
        {backendPrice != null && (
          <>
            <span className="text-gray-400">·</span>
            <span className="text-gray-600 dark:text-gray-400">Backend ({symbol}):</span>
            <span className="font-medium text-green-700 dark:text-green-400">${backendPrice.price.toFixed(2)}</span>
            <span className="text-gray-400">·</span>
          </>
        )}
        <span className="text-gray-600 dark:text-gray-400">Status:</span>
        <span
          className={`font-medium ${isStale ? 'text-amber-600 dark:text-amber-400' : 'text-green-600 dark:text-green-400'}`}
        >
          {isStale ? '⚠ Stale' : '✓ Fresh'}
        </span>
      </p>
      {isStale && (
        <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">
          Chain oracle has no recent update (used for lending/perp). Relayer must update; chart uses backend price.
        </p>
      )}
    </div>
  );
}
