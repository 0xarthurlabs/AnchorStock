'use client';

import { useEffect, useState } from 'react';
import { useAccount, useReadContract } from 'wagmi';
import { formatEther, formatUnits } from 'viem';
import { CONTRACTS, LENDING_POOL_ABI, PERP_ENGINE_ABI } from '../lib/contracts';

interface StatusCardProps {
  title: string;
  value: string;
  subtitle?: string;
  status?: 'healthy' | 'warning' | 'danger';
}

function StatusCard({ title, value, subtitle, status = 'healthy' }: StatusCardProps) {
  const statusColors = {
    healthy: 'border-green-500 bg-green-50 dark:bg-green-900/20',
    warning: 'border-yellow-500 bg-yellow-50 dark:bg-yellow-900/20',
    danger: 'border-red-500 bg-red-50 dark:bg-red-900/20',
  };

  return (
    <div className={`p-6 rounded-lg border-2 ${statusColors[status]} dark:bg-gray-800`}>
      <h3 className="text-sm font-medium text-gray-600 dark:text-gray-400 mb-1">{title}</h3>
      <p className="text-2xl font-bold text-gray-900 dark:text-white">{value}</p>
      {subtitle && <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">{subtitle}</p>}
    </div>
  );
}

export function UserStatusCards() {
  const [mounted, setMounted] = useState(false);
  const { address } = useAccount();

  // Prevent hydration mismatch / 防止水合不匹配
  useEffect(() => {
    setMounted(true);
  }, []);

  // Read health factor from LendingPool (on-chain)
  const { data: lendingHealthFactor } = useReadContract({
    address: CONTRACTS.LENDING_POOL!,
    abi: LENDING_POOL_ABI,
    functionName: 'getAccountHealthFactor',
    args: address ? [address] : undefined,
    enabled: !!address && !!CONTRACTS.LENDING_POOL,
  });

  // Read health factor from PerpEngine (on-chain) / 从 PerpEngine 读取健康因子（链上）
  const { data: perpHealthFactor } = useReadContract({
    address: CONTRACTS.PERP_ENGINE!,
    abi: PERP_ENGINE_ABI,
    functionName: 'getPositionHealthFactor',
    args: address ? [address] : undefined,
    enabled: !!address && !!CONTRACTS.PERP_ENGINE,
  });

  // Read deposit balance (on-chain). Requires RWA token address (prop or fetch).
  // 读取存入余额（链上），需要 RWA 代币地址（通过 props 或拉取）
  const { data: depositBalance } = useReadContract({
    address: CONTRACTS.LENDING_POOL!,
    abi: LENDING_POOL_ABI,
    functionName: 'deposits',
    args: address && CONTRACTS.ORACLE ? [address, CONTRACTS.ORACLE] : undefined,
    enabled: !!address && !!CONTRACTS.ORACLE && !!CONTRACTS.LENDING_POOL,
  });

  // Show loading state during hydration / 水合期间显示加载状态
  if (!mounted) {
    return (
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="p-6 rounded-lg border-2 border-gray-200 dark:border-gray-700 animate-pulse">
          <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded w-1/2 mb-2"></div>
          <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-1/3"></div>
        </div>
        <div className="p-6 rounded-lg border-2 border-gray-200 dark:border-gray-700 animate-pulse">
          <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded w-1/2 mb-2"></div>
          <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-1/3"></div>
        </div>
        <div className="p-6 rounded-lg border-2 border-gray-200 dark:border-gray-700 animate-pulse">
          <div className="h-4 bg-gray-200 dark:bg-gray-700 rounded w-1/2 mb-2"></div>
          <div className="h-8 bg-gray-200 dark:bg-gray-700 rounded w-1/3"></div>
        </div>
      </div>
    );
  }

  if (!address) {
    return (
      <div className="text-center py-8 text-gray-500">
        Connect your wallet to view your status
      </div>
    );
  }

  // Format health factor
  const formatHealthFactor = (hf: bigint | undefined) => {
    if (!hf) return 'N/A';
    const hfNumber = Number(formatEther(hf));
    if (hfNumber >= 2.0) return hfNumber.toFixed(2);
    if (hfNumber >= 1.0) return hfNumber.toFixed(2);
    return hfNumber.toFixed(4);
  };

  // Determine status based on health factor / 根据健康因子确定状态
  const getHealthStatus = (hf: bigint | undefined): 'healthy' | 'warning' | 'danger' => {
    if (!hf) return 'healthy';
    const hfNumber = Number(formatEther(hf));
    if (hfNumber < 1.0) return 'danger';
    if (hfNumber < 1.5) return 'warning';
    return 'healthy';
  };

  const lendingHF = lendingHealthFactor as bigint | undefined;
  const perpHF = perpHealthFactor as bigint | undefined;

  return (
    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
      <StatusCard
        title="Lending Pool Health Factor"
        value={formatHealthFactor(lendingHF)}
        subtitle={lendingHF ? (Number(formatEther(lendingHF)) < 1.0 ? 'Liquidatable' : 'Safe') : 'No position'}
        status={getHealthStatus(lendingHF)}
      />
      <StatusCard
        title="Perpetual Position Health Factor"
        value={formatHealthFactor(perpHF)}
        subtitle={perpHF ? (Number(formatEther(perpHF)) < 1.0 ? 'Liquidatable' : 'Safe') : 'No position'}
        status={getHealthStatus(perpHF)}
      />
      <StatusCard
        title="Deposit Balance"
        value={depositBalance ? `${formatEther(depositBalance as bigint)} RWA` : '0 RWA'}
        subtitle="Collateral deposited"
        status="healthy"
      />
    </div>
  );
}
