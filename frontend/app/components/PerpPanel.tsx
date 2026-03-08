'use client';

import { useState, useEffect } from 'react';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { formatEther, parseEther, createPublicClient, http, maxUint256 } from 'viem';
import { CONTRACTS, LENDING_POOL_ABI, PERP_ENGINE_ABI } from '../lib/contracts';
import { config } from '../lib/wagmi';
import { ToastModal, type ToastState } from './ToastModal';

const BACKEND_API_URL = process.env.NEXT_PUBLIC_BACKEND_API_URL || 'http://localhost:3001';
const RWA_SYMBOL = 'NVDA'; // Same as PerpEngine stockSymbol / 与 PerpEngine stockSymbol 一致

// Initial margin rate (10%) for frontend validation / 初始保证金率（10%）用于前端校验
const INITIAL_MARGIN_RATE = 0.1;
// Min health factor below which we warn before withdraw / 低于此健康因子时提款前提示
const HF_WARN_THRESHOLD = 1.5;

// PositionSide: LONG = 0, SHORT = 1 / 仓位方向：多=0，空=1
const SIDE_LONG = 0;
const SIDE_SHORT = 1;

interface PerpPanelProps {
  rwaTokenAddress?: `0x${string}`;
  /** aToken address (collateral). If not set, derived from LendingPool.aTokens(rwaToken). / aToken 地址（保证金）；未设置时从 LendingPool.aTokens(rwaToken) 解析 */
  aTokenAddress?: `0x${string}`;
}

export function PerpPanel({ rwaTokenAddress, aTokenAddress: aTokenAddressProp }: PerpPanelProps) {
  const { address } = useAccount();
  const [mounted, setMounted] = useState(false);
  const [activeTab, setActiveTab] = useState<'open' | 'close' | 'add' | 'withdraw'>('open');
  const [side, setSide] = useState<0 | 1>(SIDE_LONG);
  const [openSize, setOpenSize] = useState('');
  const [openCollateral, setOpenCollateral] = useState('');
  const [closeSize, setCloseSize] = useState('');
  const [addCollateralAmount, setAddCollateralAmount] = useState('');
  const [withdrawCollateralAmount, setWithdrawCollateralAmount] = useState('');
  const [markPrice, setMarkPrice] = useState<number>(0);
  const [toast, setToast] = useState<ToastState>({ open: false, type: 'info', message: '' });
  const [openError, setOpenError] = useState<string | null>(null);
  const [closeError, setCloseError] = useState<string | null>(null);
  const [addError, setAddError] = useState<string | null>(null);
  const [withdrawError, setWithdrawError] = useState<string | null>(null);

  const showToast = (opts: { type: ToastState['type']; title?: string; message: string; txHash?: string }) => {
    setToast({ open: true, ...opts });
  };
  const closeToast = () => setToast((t) => ({ ...t, open: false }));

  const { writeContractAsync, data: hash, isPending, error } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({ hash });

  useEffect(() => setMounted(true), []);

  // Resolve aToken address: prop, or from LendingPool.aTokens(rwaToken) / 解析 aToken 地址
  const { data: aTokenFromPool } = useReadContract({
    address: CONTRACTS.LENDING_POOL,
    abi: LENDING_POOL_ABI,
    functionName: 'aTokens',
    args: rwaTokenAddress ? [rwaTokenAddress] : undefined,
    query: { enabled: !!CONTRACTS.LENDING_POOL && !!rwaTokenAddress && !aTokenAddressProp },
  });
  const aTokenAddress = (aTokenAddressProp ?? (aTokenFromPool as `0x${string}` | undefined)) as `0x${string}` | undefined;

  // Fetch mark price for display / 拉取标记价格
  useEffect(() => {
    let cancelled = false;
    fetch(`${BACKEND_API_URL}/api/price/${RWA_SYMBOL}`)
      .then((res) => (res.ok ? res.json() : null))
      .then((data: { price?: number } | null) => {
        if (!cancelled && data && typeof data.price === 'number') setMarkPrice(data.price);
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, []);

  // Read position / 读取仓位
  const { data: positionData, refetch: refetchPosition } = useReadContract({
    address: CONTRACTS.PERP_ENGINE,
    abi: PERP_ENGINE_ABI,
    functionName: 'positions',
    args: address ? [address] : undefined,
    query: { enabled: !!address && !!CONTRACTS.PERP_ENGINE },
  });

  const { data: healthFactor } = useReadContract({
    address: CONTRACTS.PERP_ENGINE,
    abi: PERP_ENGINE_ABI,
    functionName: 'getPositionHealthFactor',
    args: address ? [address] : undefined,
    query: { enabled: !!address && !!CONTRACTS.PERP_ENGINE },
  }); // Read health factor / 读取健康因子

  // aToken balance (collateral available to open/add) / aToken 余额（可用于开仓/加保）
  const { data: aTokenBalance } = useReadContract({
    address: aTokenAddress,
    abi: [{ inputs: [{ name: 'account', type: 'address' }], name: 'balanceOf', outputs: [{ name: '', type: 'uint256' }], stateMutability: 'view', type: 'function' }],
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address && !!aTokenAddress },
  });

  const position = positionData as [number, bigint, bigint, bigint, bigint, bigint] | undefined;
  const hasPosition = position && position[1] !== BigInt(0); // size > 0 / 仓位 size 大于 0
  const posSide = position ? Number(position[0]) : 0;
  const posSize = position ? position[1] : BigInt(0);
  const posEntryPrice = position ? position[2] : BigInt(0);
  const posCollateral = position ? position[3] : BigInt(0);

  const formatHf = (hf: bigint | undefined): string => {
    if (!hf) return 'N/A';
    const h = Number(formatEther(hf));
    if (h >= 1e10) return '∞ (Safe)';
    return h.toFixed(4);
  };

  function parsePositiveEther(s: string): { value: bigint; error?: string } {
    const trimmed = s.trim();
    if (!trimmed) return { value: BigInt(0), error: 'Required.' };
    const num = parseFloat(trimmed);
    if (Number.isNaN(num)) return { value: BigInt(0), error: 'Invalid number.' };
    if (num <= 0) return { value: BigInt(0), error: 'Must be greater than 0.' };
    if (num > 1e30) return { value: BigInt(0), error: 'Value too large.' };
    try {
      const value = parseEther(trimmed);
      if (value === BigInt(0)) return { value: BigInt(0), error: 'Amount too small.' };
      return { value };
    } catch {
      return { value: BigInt(0), error: 'Invalid format (use up to 18 decimals).' };
    }
  }

  // Ensure aToken allowance for PerpEngine, approve if needed / 确保 PerpEngine 有 aToken 授权，不足则先 approve
  const ensureApproval = async (amount: bigint) => {
    if (!aTokenAddress || !CONTRACTS.PERP_ENGINE || !address) return;
    const chain = config.chains[0];
    const publicClient = createPublicClient({ chain, transport: http(chain.rpcUrls.default.http[0]) });
    const currentAllowance = await publicClient.readContract({
      address: aTokenAddress,
      abi: [{ inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }], name: 'allowance', outputs: [{ name: '', type: 'uint256' }], stateMutability: 'view', type: 'function' }],
      functionName: 'allowance',
      args: [address, CONTRACTS.PERP_ENGINE],
    });
    if (currentAllowance < amount) {
      const approveHash = await writeContractAsync({
        address: aTokenAddress,
        abi: [{ inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], name: 'approve', outputs: [{ name: '', type: 'bool' }], stateMutability: 'nonpayable', type: 'function' }],
        functionName: 'approve',
        args: [CONTRACTS.PERP_ENGINE, maxUint256],
      });
      showToast({ type: 'info', title: 'Approval submitted', message: 'Wait for confirmation, then retry.', txHash: approveHash });
      await publicClient.waitForTransactionReceipt({ hash: approveHash as `0x${string}` });
    }
  };

  // Open long/short position with size and collateral / 开多/空仓，传入 size 与保证金
  const handleOpenPosition = async () => {
    setOpenError(null);
    if (!CONTRACTS.PERP_ENGINE || !aTokenAddress) {
      showToast({ type: 'error', message: 'PerpEngine or aToken address not configured.' });
      return;
    }
    const sizeResult = parsePositiveEther(openSize);
    const collateralResult = parsePositiveEther(openCollateral);
    if (sizeResult.error) {
      setOpenError('Size: ' + sizeResult.error);
      return;
    }
    if (collateralResult.error) {
      setOpenError('Collateral: ' + collateralResult.error);
      return;
    }
    const size = sizeResult.value;
    const collateralAmount = collateralResult.value;

    const aBal = aTokenBalance ?? BigInt(0);
    if (collateralAmount > aBal) {
      setOpenError('Insufficient aToken. Available: ' + formatEther(aBal) + ' aRWA. Deposit RWA in Lending first.');
      return;
    }
    if (markPrice > 0) {
      // 合约逻辑：requiredCollateral = size * initialMarginRate（单位都是 aRWA，不是美元）
      const sizeNum = Number(formatEther(size));
      const requiredCollateralNum = sizeNum * INITIAL_MARGIN_RATE;
      const collateralNum = Number(formatEther(collateralAmount));
      if (collateralNum < requiredCollateralNum) {
        setOpenError('Collateral may be too low. Required >= ' + requiredCollateralNum.toFixed(4) + ' aRWA (' + (INITIAL_MARGIN_RATE * 100) + '% of size).');
        return;
      }
    }

    try {
      await ensureApproval(collateralAmount);
      const txHash = await writeContractAsync({
        address: CONTRACTS.PERP_ENGINE,
        abi: PERP_ENGINE_ABI,
        functionName: 'openPosition',
        args: [side, size, collateralAmount],
      });
      showToast({ type: 'success', title: 'Open position submitted', message: 'Wait for on-chain confirmation.', txHash });
      setOpenSize('');
      setOpenCollateral('');
      setOpenError(null);
      refetchPosition();
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      showToast({ type: 'error', message: `Open position failed: ${msg}` });
    }
  };

  // Close position (full or partial by size) / 平仓（全部或按 size 部分平仓）
  const handleClosePosition = async () => {
    setCloseError(null);
    if (!CONTRACTS.PERP_ENGINE) {
      showToast({ type: 'error', message: 'PerpEngine not configured.' });
      return;
    }
    let sizeToClose: bigint;
    if (closeSize.trim() === '') {
      sizeToClose = posSize;
    } else {
      const result = parsePositiveEther(closeSize);
      if (result.error) {
        setCloseError('Size to close: ' + result.error);
        return;
      }
      sizeToClose = result.value;
    }
    if (sizeToClose > posSize) {
      setCloseError('Close size exceeds position (max ' + formatEther(posSize) + ').');
      return;
    }
    if (sizeToClose === BigInt(0)) {
      setCloseError('Enter a valid size to close.');
      return;
    }
    try {
      const txHash = await writeContractAsync({
        address: CONTRACTS.PERP_ENGINE,
        abi: PERP_ENGINE_ABI,
        functionName: 'closePosition',
        args: [sizeToClose],
      });
      showToast({ type: 'success', title: 'Close position submitted', message: 'Wait for on-chain confirmation.', txHash });
      setCloseSize('');
      setCloseError(null);
      refetchPosition();
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      showToast({ type: 'error', message: `Close position failed: ${msg}` });
    }
  };

  const handleAddCollateral = async () => {
    setAddError(null);
    if (!CONTRACTS.PERP_ENGINE || !aTokenAddress) {
      showToast({ type: 'error', message: 'PerpEngine or aToken not configured.' });
      return;
    }
    const result = parsePositiveEther(addCollateralAmount);
    if (result.error) {
      setAddError(result.error);
      return;
    }
    const amount = result.value;
    const aBal = aTokenBalance ?? BigInt(0);
    if (amount > aBal) {
      setAddError('Insufficient aToken. Available: ' + formatEther(aBal) + ' aRWA.');
      return;
    }
    try {
      await ensureApproval(amount);
      const txHash = await writeContractAsync({
        address: CONTRACTS.PERP_ENGINE,
        abi: PERP_ENGINE_ABI,
        functionName: 'addCollateral',
        args: [amount],
      });
      showToast({ type: 'success', title: 'Add collateral submitted', message: 'Wait for on-chain confirmation.', txHash });
      setAddCollateralAmount('');
      setAddError(null);
      refetchPosition();
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      showToast({ type: 'error', message: `Add collateral failed: ${msg}` });
    }
  };

  // Withdraw collateral from position (within safe limit) / 从仓位提取保证金（在安全范围内）
  const handleWithdrawCollateral = async () => {
    setWithdrawError(null);
    if (!CONTRACTS.PERP_ENGINE) {
      showToast({ type: 'error', message: 'PerpEngine not configured.' });
      return;
    }
    const result = parsePositiveEther(withdrawCollateralAmount);
    if (result.error) {
      setWithdrawError(result.error);
      return;
    }
    const amount = result.value;
    if (amount > posCollateral) {
      setWithdrawError('Amount exceeds collateral in position (max ' + formatEther(posCollateral) + ' aRWA).');
      return;
    }
    const hfNumForWithdraw = healthFactor ? Number(formatEther(healthFactor as bigint)) : 0;
    if (hfNumForWithdraw > 0 && hfNumForWithdraw < HF_WARN_THRESHOLD) {
      showToast({ type: 'info', message: 'Health factor is low. Large withdraw may fail on-chain or increase liquidation risk.' });
    }
    try {
      const txHash = await writeContractAsync({
        address: CONTRACTS.PERP_ENGINE,
        abi: PERP_ENGINE_ABI,
        functionName: 'withdrawCollateral',
        args: [amount],
      });
      showToast({ type: 'success', title: 'Withdraw collateral submitted', message: 'Wait for on-chain confirmation.', txHash });
      setWithdrawCollateralAmount('');
      setWithdrawError(null);
      refetchPosition();
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      showToast({ type: 'error', message: `Withdraw collateral failed: ${msg}` });
    }
  };

  if (!mounted) {
    // Loading skeleton during hydration / 水合期间加载骨架
    return (
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700 animate-pulse">
        <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-1/4 mb-4" />
      </div>
    );
  }

  if (!address) {
    return (
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
        <p className="text-center text-gray-500">Connect your wallet to use perpetual contracts.</p>
      </div>
    );
  }

  if (!CONTRACTS.PERP_ENGINE) {
    return (
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
        <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
          Perpetual Contracts
          <span className="ml-3 inline-flex items-center rounded-full bg-amber-100 dark:bg-amber-900/40 px-3 py-1 text-sm font-medium text-amber-800 dark:text-amber-200 ring-1 ring-amber-600/20">
            Single stock per contract (currently NVDA)
          </span>
        </h2>
        <p className="text-gray-500">PerpEngine contract address not configured. Set NEXT_PUBLIC_PERP_ENGINE_CONTRACT_ADDRESS in .env.local.</p>
      </div>
    );
  }

  const aBalNum = aTokenBalance ? Number(formatEther(aTokenBalance as bigint)) : 0;
  const hfNum = healthFactor ? Number(formatEther(healthFactor as bigint)) : 0;

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
      <ToastModal state={toast} onClose={closeToast} />
      <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-6">
        Perpetual Contracts
        <span className="ml-3 inline-flex items-center rounded-full bg-amber-100 dark:bg-amber-900/40 px-3 py-1 text-sm font-medium text-amber-800 dark:text-amber-200 ring-1 ring-amber-600/20">
          Single stock per contract (currently NVDA)
        </span>
      </h2>

      <div className="flex space-x-2 mb-6 border-b border-gray-200 dark:border-gray-700">
        {(['open', 'close', 'add', 'withdraw'] as const).map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            className={`px-4 py-2 font-medium capitalize ${activeTab === tab ? 'text-blue-600 dark:text-blue-400 border-b-2 border-blue-600 dark:border-blue-400' : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300'}`}
          >
            {tab === 'open' ? 'Open' : tab === 'close' ? 'Close' : tab === 'add' ? 'Add collateral' : 'Withdraw collateral'}
          </button>
        ))}
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">Position</p>
          <p className="text-lg font-semibold text-gray-900 dark:text-white">
            {hasPosition ? (posSide === SIDE_LONG ? 'Long' : 'Short') + ` ${formatEther(posSize)}` : 'No position'}
          </p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">Entry price</p>
          <p className="text-lg font-semibold text-gray-900 dark:text-white">{hasPosition ? `$${Number(formatEther(posEntryPrice)).toFixed(2)}` : '—'}</p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">Collateral (aRWA)</p>
          <p className="text-lg font-semibold text-gray-900 dark:text-white">{hasPosition ? formatEther(posCollateral) : '—'}</p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">Health factor</p>
          <p className={`text-lg font-semibold ${hfNum >= 1.5 ? 'text-green-600' : hfNum >= 1 ? 'text-yellow-600' : 'text-red-600'}`}>{formatHf(healthFactor as bigint | undefined)}</p>
        </div>
      </div>

      <p className="text-sm text-gray-500 mb-4">Mark price ({RWA_SYMBOL}): ${markPrice.toFixed(2)} · aToken balance: {aBalNum.toFixed(4)} aRWA (deposit RWA in Lending to get aToken)</p>

      {activeTab === 'open' && (
        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Direction</label>
            <div className="flex gap-4">
              <label className="flex items-center gap-2 cursor-pointer">
                <input type="radio" checked={side === SIDE_LONG} onChange={() => setSide(SIDE_LONG)} className="rounded-full" />
                <span>Long</span>
              </label>
              <label className="flex items-center gap-2 cursor-pointer">
                <input type="radio" checked={side === SIDE_SHORT} onChange={() => setSide(SIDE_SHORT)} className="rounded-full" />
                <span>Short</span>
              </label>
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Size (quantity, e.g. 1 or 0.5)</label>
            <input type="number" value={openSize} onChange={(e) => { setOpenSize(e.target.value); setOpenError(null); }} placeholder="0" min="0" step="any" className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white" />
            {openSize && parseFloat(openSize) > 0 && (
              <p className="mt-1 text-sm text-gray-500">Min collateral ≥ {(parseFloat(openSize) * INITIAL_MARGIN_RATE).toFixed(4)} aRWA (10% of size)</p>
            )}
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Collateral (aRWA)</label>
            <div className="flex gap-2 items-center">
              <input type="number" value={openCollateral} onChange={(e) => { setOpenCollateral(e.target.value); setOpenError(null); }} placeholder="0" min="0" step="any" className="flex-1 px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white" />
              {openSize && parseFloat(openSize) > 0 && (
                <button type="button" onClick={() => setOpenCollateral((parseFloat(openSize) * INITIAL_MARGIN_RATE).toFixed(4))} className="px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-600 whitespace-nowrap">Fill minimum</button>
              )}
            </div>
            <p className="mt-1 text-sm text-gray-500">Available: {aBalNum.toFixed(4)} aRWA</p>
            {openCollateral && parseFloat(openCollateral) > 0 && (
              <p className="mt-0.5 text-sm text-gray-500">Current collateral can open max Size ≈ {(parseFloat(openCollateral) / INITIAL_MARGIN_RATE).toFixed(2)} (reference only)</p>
            )}
          </div>
          {openError && <p className="text-sm text-red-600 dark:text-red-400">{openError}</p>}
          <button onClick={handleOpenPosition} disabled={isPending || isConfirming || !openSize || !openCollateral || parseFloat(openSize) <= 0 || parseFloat(openCollateral) <= 0} className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed">
            {isPending || isConfirming ? 'Processing...' : 'Open position'}
          </button>
        </div>
      )}

      {activeTab === 'close' && (
        <div className="space-y-4">
          {!hasPosition ? (
            <p className="text-gray-500">You have no open position. Open a position first.</p>
          ) : (
            <>
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Size to close (leave empty to close full)</label>
                <input type="number" value={closeSize} onChange={(e) => { setCloseSize(e.target.value); setCloseError(null); }} placeholder={formatEther(posSize)} min="0" step="any" className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white" />
                <p className="mt-1 text-sm text-gray-500">Position size: {formatEther(posSize)}</p>
              </div>
              {closeError && <p className="text-sm text-red-600 dark:text-red-400">{closeError}</p>}
              <button onClick={handleClosePosition} disabled={isPending || isConfirming} className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed">
                {isPending || isConfirming ? 'Processing...' : 'Close position'}
              </button>
            </>
          )}
        </div>
      )}

      {activeTab === 'add' && (
        <div className="space-y-4">
          {!hasPosition ? (
            <p className="text-gray-500">You have no open position. Open a position first.</p>
          ) : (
            <>
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Amount (aRWA)</label>
                <input type="number" value={addCollateralAmount} onChange={(e) => { setAddCollateralAmount(e.target.value); setAddError(null); }} placeholder="0" min="0" step="any" className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white" />
                <p className="mt-1 text-sm text-gray-500">Available: {aBalNum.toFixed(4)} aRWA</p>
              </div>
              {addError && <p className="text-sm text-red-600 dark:text-red-400">{addError}</p>}
              <button onClick={handleAddCollateral} disabled={isPending || isConfirming || !addCollateralAmount || parseFloat(addCollateralAmount) <= 0} className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed">
                {isPending || isConfirming ? 'Processing...' : 'Add collateral'}
              </button>
            </>
          )}
        </div>
      )}

      {activeTab === 'withdraw' && (
        <div className="space-y-4">
          {!hasPosition ? (
            <p className="text-gray-500">You have no open position.</p>
          ) : (
            <>
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Amount (aRWA)</label>
                <input type="number" value={withdrawCollateralAmount} onChange={(e) => { setWithdrawCollateralAmount(e.target.value); setWithdrawError(null); }} placeholder="0" min="0" step="any" className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white" />
                <p className="mt-1 text-sm text-gray-500">Collateral in position: {formatEther(posCollateral)} aRWA</p>
              </div>
              {withdrawError && <p className="text-sm text-red-600 dark:text-red-400">{withdrawError}</p>}
              <button onClick={handleWithdrawCollateral} disabled={isPending || isConfirming || !withdrawCollateralAmount || parseFloat(withdrawCollateralAmount) <= 0 || parseFloat(withdrawCollateralAmount) > Number(formatEther(posCollateral))} className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed">
                {isPending || isConfirming ? 'Processing...' : 'Withdraw collateral'}
              </button>
            </>
          )}
        </div>
      )}

      {error && (
        <div className="mt-4 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded">
          <p className="text-sm text-red-800 dark:text-red-200">Error: {error.message}</p>
        </div>
      )}
      {isConfirmed && (
        <div className="mt-4 p-3 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded">
          <p className="text-sm text-green-800 dark:text-green-200">Transaction confirmed.</p>
        </div>
      )}
    </div>
  );
}
