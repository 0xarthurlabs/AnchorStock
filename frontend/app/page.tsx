'use client';

import { useState, useEffect } from 'react';
import { Header } from './components/Header';
import { KLineChart } from './components/KLineChart';
import { UserStatusCards } from './components/StatusCard';
import { OracleStatus } from './components/OracleStatus';
import { LendingPanel } from './components/LendingPanel';
import { PerpPanel } from './components/PerpPanel';
import { OHLCV } from './types';
import { useRuntimeConfig } from './lib/runtimeConfig';

// 与后端 STOCK_SYMBOLS 默认一致，界面可选多只股票 / Same as backend default, UI can switch between symbols
const STOCK_SYMBOLS = ['NVDA', 'AAPL', 'TSLA', 'MSFT'] as const;
export type StockSymbol = (typeof STOCK_SYMBOLS)[number];

// Mock base price per symbol when backend has no OHLCV (so chart still displays for AAPL/TSLA/MSFT)
const MOCK_BASE_PRICE: Record<StockSymbol, number> = { NVDA: 177, AAPL: 230, TSLA: 260, MSFT: 420 };

function buildMockKline(symbol: StockSymbol, count: number): OHLCV[] {
  const base = MOCK_BASE_PRICE[symbol];
  const now = Math.floor(Date.now() / 1000);
  return Array.from({ length: count }, (_, i) => {
    const t = now - (count - 1 - i) * 3600;
    const o = base + (Math.random() - 0.5) * 10;
    const c = o + (Math.random() - 0.5) * 8;
    const h = Math.max(o, c) + Math.random() * 4;
    const l = Math.min(o, c) - Math.random() * 4;
    return {
      time: t,
      open: o,
      high: h,
      low: l,
      close: c,
      volume: Math.floor(Math.random() * 1_000_000) + 500_000,
    };
  });
}

export default function Home() {
  const [klineData, setKlineData] = useState<OHLCV[]>([]);
  const [loading, setLoading] = useState(true);
  const [mounted, setMounted] = useState(false);
  const [mainTab, setMainTab] = useState<'lending' | 'perp'>('lending');
  const [symbol, setSymbol] = useState<StockSymbol>('NVDA');
  const { app, contracts } = useRuntimeConfig();

  // Prevent hydration mismatch / 防止水合不匹配
  useEffect(() => {
    setMounted(true);
  }, []);

  // Fetch K-line data from backend API; use mock for symbol when backend returns empty (e.g. AAPL/TSLA/MSFT)
  useEffect(() => {
    const fetchKlineData = async () => {
      try {
        setLoading(true);
        const response = await fetch(`${app.backendApiUrl}/api/ohlcv?symbol=${symbol}&interval=1h&limit=100`);
        if (response.ok) {
          const data = await response.json();
          if (Array.isArray(data) && data.length >= 2) {
            setKlineData(data);
          } else {
            setKlineData(buildMockKline(symbol, 100));
          }
        } else {
          setKlineData(buildMockKline(symbol, 100));
        }
      } catch (error) {
        console.error('Error fetching K-line data:', error);
        setKlineData(buildMockKline(symbol, 100));
      } finally {
        setLoading(false);
      }
    };

    fetchKlineData();
    const interval = setInterval(fetchKlineData, 30000);
    return () => clearInterval(interval);
  }, [symbol]);

  // Show loading state until client hydrated (wallet etc.); skeleton is client-only so no extension hydration issue / 水合完成前显示加载骨架（仅客户端渲染，无扩展导致的水合问题）
  if (!mounted) {
    return (
      <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
        <div className="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 h-16" />
        <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="space-y-6">
            <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700 animate-pulse">
              <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-1/4 mb-4" />
            </div>
            <div className="w-full bg-gray-900 rounded-lg p-4" style={{ height: '260px' }} />
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="p-6 rounded-lg border-2 border-gray-200 dark:border-gray-700 animate-pulse" />
              <div className="p-6 rounded-lg border-2 border-gray-200 dark:border-gray-700 animate-pulse" />
              <div className="p-6 rounded-lg border-2 border-gray-200 dark:border-gray-700 animate-pulse" />
            </div>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
      <Header />
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="space-y-6">
          {/* Symbol selector: switch stock for Oracle & Chart / 股票切换 */}
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-medium text-gray-600 dark:text-gray-400">Symbol:</span>
            {STOCK_SYMBOLS.map((s) => (
              <button
                key={s}
                type="button"
                onClick={() => setSymbol(s)}
                className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
                  symbol === s
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-300 dark:hover:bg-gray-600'
                }`}
              >
                {s}
              </button>
            ))}
          </div>

          {/* Oracle Status */}
          <OracleStatus symbol={symbol} />

          {/* K-line Chart */}
          {loading ? (
            <div className="w-full bg-gray-900 rounded-lg p-4 flex items-center justify-center" style={{ height: '260px' }}>
              <p className="text-white">Loading chart data...</p>
            </div>
          ) : (
            <KLineChart data={klineData} symbol={symbol} />
          )}

          {/* User Status Cards */}
          <UserStatusCards />

          {/* Main tabs: Lending vs Perpetual / 主选项卡 */}
          <div className="flex gap-2 border-b-2 border-gray-200 dark:border-gray-700">
            <button
              type="button"
              onClick={() => setMainTab('lending')}
              className={`flex-1 py-4 px-6 text-lg font-semibold rounded-t-lg transition-colors ${
                mainTab === 'lending'
                  ? 'bg-blue-600 text-white border-2 border-blue-600 border-b-0 -mb-0.5 shadow-sm'
                  : 'bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400 hover:bg-gray-200 dark:hover:bg-gray-700 border-2 border-transparent'
              }`}
            >
              Lending & Borrowing
            </button>
            <button
              type="button"
              onClick={() => setMainTab('perp')}
              className={`flex-1 py-4 px-6 text-lg font-semibold rounded-t-lg transition-colors ${
                mainTab === 'perp'
                  ? 'bg-blue-600 text-white border-2 border-blue-600 border-b-0 -mb-0.5 shadow-sm'
                  : 'bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400 hover:bg-gray-200 dark:hover:bg-gray-700 border-2 border-transparent'
              }`}
            >
              Perpetual Contracts
            </button>
          </div>

          {/* Tab content: only render active panel / 仅渲染当前选中的面板 */}
          {mainTab === 'lending' && (
            <LendingPanel
              rwaTokenAddress={contracts.RWA_TOKEN}
              usdTokenAddress={contracts.USD_TOKEN}
            />
          )}
          {mainTab === 'perp' && (
            <PerpPanel
              rwaTokenAddress={contracts.RWA_TOKEN}
              aTokenAddress={contracts.A_TOKEN}
            />
          )}
        </div>
      </main>
    </div>
  );
}
