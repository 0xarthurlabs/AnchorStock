'use client';

import { useState, useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { formatEther, parseEther, formatUnits, parseUnits, createPublicClient, http, maxUint256, decodeErrorResult } from 'viem';
import { LENDING_POOL_ABI } from '../lib/contracts';
import { ToastModal, type ToastState } from './ToastModal';
import { useRuntimeConfig } from '../lib/runtimeConfig';

const RWA_SYMBOL = 'NVDA'; // Same as LendingPool stockSymbol / 与 LendingPool stockSymbol 一致
const LTV = 0.7; // 70%

// ABI for revert decoding: Error(string), Panic(uint256), and LendingPool custom errors
const REVERT_ABI = [
  { type: 'error' as const, name: 'Error', inputs: [{ name: 'message', type: 'string' }] },
  { type: 'error' as const, name: 'Panic', inputs: [{ name: 'code', type: 'uint256' }] },
  { type: 'error' as const, name: 'HealthFactorTooLow', inputs: [{ name: 'healthFactor', type: 'uint256' }] },
  { type: 'error' as const, name: 'BorrowLimitExceeded', inputs: [] },
  { type: 'error' as const, name: 'AssetNotSupported', inputs: [] },
];

/** Collect first hex data from error or its cause chain (for decoding) */
function getRevertData(err: unknown): `0x${string}` | undefined {
  let cur: unknown = err;
  while (cur && typeof cur === 'object') {
    const e = cur as { data?: unknown; cause?: unknown };
    if (e.data && typeof e.data === 'string' && (e.data as string).startsWith('0x')) return e.data as `0x${string}`;
    cur = e.cause;
  }
  return undefined;
}

/** Parse revert reason from contract error — 100% capture for UI and console. Logs full error. */
function parseRevertReason(err: unknown): string {
  const data = getRevertData(err);
  if (data && data.length > 10) {
    try {
      const decoded = decodeErrorResult({ abi: REVERT_ABI, data });
      const name = decoded.errorName;
      const args = decoded.args;
      if (name === 'Error' && args != null && typeof (args as unknown as { message?: string }).message === 'string') {
        return (args as unknown as { message: string }).message.trim();
      }
      if (name === 'Panic' && args !== undefined) {
        const code = typeof args === 'object' && args !== null && 'code' in args ? Number((args as unknown as { code: bigint }).code) : undefined;
        const panicMessages: Record<number, string> = {
          0x11: 'SafeMath: subtraction overflow',
          0x12: 'SafeMath: division by zero',
          0x31: 'SafeMath: multiplication overflow',
          0x32: 'Array index out of bounds',
          0x41: 'Memory overflow',
          0x51: 'Invalid opcode',
        };
        return panicMessages[code ?? 0] ?? `Panic(${code ?? 'unknown'})`;
      }
      if (name === 'BorrowLimitExceeded') return 'LendingPool: borrow limit exceeded';
      if (name === 'HealthFactorTooLow' && args && typeof (args as unknown as { healthFactor?: bigint }).healthFactor !== 'undefined') {
        return `LendingPool: health factor too low (${(args as unknown as { healthFactor: bigint }).healthFactor})`;
      }
      if (name === 'AssetNotSupported') return 'LendingPool: asset not supported';
      return name ? `Contract error: ${name}` : String(args);
    } catch (_) {
      // fall through to generic extraction
    }
  }
  const short = (err as { shortMessage?: string })?.shortMessage;
  if (typeof short === 'string' && short.trim()) return short.trim();
  const msg = err instanceof Error ? err.message : String(err);
  if (msg && msg.trim()) return msg.trim();
  return 'Transaction reverted (reason unknown).';
}

interface LendingPanelProps {
  rwaTokenAddress?: `0x${string}`;
  usdTokenAddress?: `0x${string}`;
}

export function LendingPanel({ rwaTokenAddress, usdTokenAddress }: LendingPanelProps) {
  const { address } = useAccount();
  const [mounted, setMounted] = useState(false);
  const { app, contracts } = useRuntimeConfig();
  const [activeTab, setActiveTab] = useState<'deposit' | 'borrow' | 'withdraw' | 'repay'>('deposit');
  const [depositAmount, setDepositAmount] = useState('');
  const [borrowAmount, setBorrowAmount] = useState('');
  const [withdrawAmount, setWithdrawAmount] = useState('');
  const [repayAmount, setRepayAmount] = useState('');
  const [rwaPriceUsd, setRwaPriceUsd] = useState<number>(0); // Real-time price for borrow collateral value / 实时价格，用于 borrow 抵押价值
  const [toast, setToast] = useState<ToastState>({ open: false, type: 'info', message: '' });
  /** Inline error message so user always sees something even if toast is missed / 内联错误条，确保用户一定能看到 */
  const [inlineError, setInlineError] = useState<string | null>(null);
  const toastShownForWriteErrorRef = useRef<unknown>(null);

  const showToast = (opts: { type: ToastState['type']; title?: string; message: string; txHash?: string }) => {
    setToast({ open: true, ...opts });
  };
  const closeToast = () => setToast((t) => ({ ...t, open: false }));

  const { writeContract, writeContractAsync, data: hash, isPending, error: writeError, reset: resetWrite } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({
    hash,
  });

  useEffect(() => {
    setMounted(true);
  }, []);

  // When wagmi useWriteContract sets error (e.g. revert without throwing), show toast + inline error / 当 wagmi 只设置 error 不抛错时也提示
  useEffect(() => {
    if (!writeError || toastShownForWriteErrorRef.current === writeError) return;
    toastShownForWriteErrorRef.current = writeError;
    console.error('[Lending] useWriteContract error (full):', writeError);
    const msg = parseRevertReason(writeError);
    setInlineError(msg);
    setToast({ open: true, type: 'error', title: 'Transaction failed', message: msg });
    (resetWrite as (() => void) | undefined)?.();
  }, [writeError, resetWrite]);

  // Fetch RWA real-time price (collateral value = Deposit Balance × price) / 拉取 RWA 实时价格（用于 borrow 时抵押价值 = Deposit Balance × 价格）
  useEffect(() => {
    let cancelled = false;
    fetch(`${app.backendApiUrl}/api/price/${RWA_SYMBOL}`)
      .then((res) => res.ok ? res.json() : null)
      .then((data: { price?: number } | null) => {
        if (!cancelled && data && typeof data.price === 'number') setRwaPriceUsd(data.price);
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, []);

  // Read user deposit balance / 读取用户存入余额
  const { data: depositBalance, refetch: refetchDeposits } = useReadContract({
    address: contracts.LENDING_POOL!,
    abi: LENDING_POOL_ABI,
    functionName: 'deposits',
    args: address && rwaTokenAddress ? [address, rwaTokenAddress] : undefined,
    query: {
      enabled: !!address && !!rwaTokenAddress && !!contracts.LENDING_POOL,
    },
  });

  // Read user borrow balance / 读取用户借款余额
  const { data: borrowBalance, refetch: refetchBorrows } = useReadContract({
    address: contracts.LENDING_POOL!,
    abi: LENDING_POOL_ABI,
    functionName: 'borrows',
    args: address ? [address] : undefined,
    query: {
      enabled: !!address && !!contracts.LENDING_POOL,
    },
  });

  // Read health factor
  const { data: healthFactor, refetch: refetchHealthFactor } = useReadContract({
    address: contracts.LENDING_POOL!,
    abi: LENDING_POOL_ABI,
    functionName: 'getAccountHealthFactor',
    args: address ? [address] : undefined,
    query: {
      enabled: !!address && !!contracts.LENDING_POOL,
    },
  });

  // Read RWA token balance / 读取 RWA 代币余额
  const { data: rwaBalance, refetch: refetchRwaBalance } = useReadContract({
    address: rwaTokenAddress,
    abi: [
      {
        inputs: [{ name: 'account', type: 'address' }],
        name: 'balanceOf',
        outputs: [{ name: '', type: 'uint256' }],
        stateMutability: 'view',
        type: 'function',
      },
    ],
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: {
      enabled: !!address && !!rwaTokenAddress,
    },
  });

  // Read USD token balance / 读取 USD 代币余额
  const { data: usdBalance, refetch: refetchUsdBalance } = useReadContract({
    address: usdTokenAddress,
    abi: [
      {
        inputs: [{ name: 'account', type: 'address' }],
        name: 'balanceOf',
        outputs: [{ name: '', type: 'uint256' }],
        stateMutability: 'view',
        type: 'function',
      },
    ],
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: {
      enabled: !!address && !!usdTokenAddress,
    },
  });

  // Refetch all balances and health factor when a transaction is confirmed so each tab shows up-to-date amounts
  useEffect(() => {
    if (!isConfirmed || !hash) return;
    refetchDeposits?.();
    refetchBorrows?.();
    refetchHealthFactor?.();
    refetchRwaBalance?.();
    refetchUsdBalance?.();
  }, [isConfirmed, hash, refetchDeposits, refetchBorrows, refetchHealthFactor, refetchRwaBalance, refetchUsdBalance]);

  const handleDeposit = async () => {
    if (!rwaTokenAddress || !depositAmount || parseFloat(depositAmount) <= 0) {
      console.error('Invalid deposit parameters:', { rwaTokenAddress, depositAmount });
      return;
    }

    if (!contracts.LENDING_POOL) {
      console.error('LendingPool contract address not configured');
      showToast({ type: 'error', message: 'LendingPool contract address not configured. Please check .env.local.' });
      return;
    }

    try {
      const amount = parseEther(depositAmount);
      console.log('Starting deposit process:', { amount: depositAmount, rwaTokenAddress, lendingPool: contracts.LENDING_POOL });
      
      if (!address) {
        showToast({ type: 'info', message: 'Please connect your wallet first.' });
        return;
      }

      // Prevent deposit when wallet RWA balance is insufficient (causes "execution reverted" on-chain)
      // 防止钱包 RWA 不足时存入导致链上 revert
      if (rwaBalance !== undefined && rwaBalance < amount) {
        const msg = `Insufficient RWA balance. You have ${formatEther(rwaBalance)} RWA, attempting to deposit ${depositAmount}. RWA is minted only by the contract owner—request testnet RWA from the deployer.`;
        console.error(msg);
        showToast({ type: 'error', message: msg });
        return;
      }

      // Create public client for reading contract state
      const rpcUrl = app.rpcUrl;
      const publicClient = createPublicClient({
        transport: http(rpcUrl),
      });

      // Check current allowance
      console.log('Step 1: Checking current allowance...');
      const currentAllowance = await publicClient.readContract({
        address: rwaTokenAddress,
        abi: [
          {
            inputs: [
              { name: 'owner', type: 'address' },
              { name: 'spender', type: 'address' },
            ],
            name: 'allowance',
            outputs: [{ name: '', type: 'uint256' }],
            stateMutability: 'view',
            type: 'function',
          },
        ],
        functionName: 'allowance',
        args: [address, contracts.LENDING_POOL],
      });

      console.log('Current allowance:', currentAllowance.toString());

      // Only approve if current allowance is less than amount
      const needsApproval = currentAllowance < amount;
      
      if (needsApproval) {
        console.log('Current allowance insufficient, approving max amount...');
        const approveHash = await writeContractAsync({
          address: rwaTokenAddress,
          abi: [
            {
              inputs: [
                { name: 'spender', type: 'address' },
                { name: 'amount', type: 'uint256' },
              ],
              name: 'approve',
              outputs: [{ name: '', type: 'bool' }],
              stateMutability: 'nonpayable',
              type: 'function',
            },
          ],
          functionName: 'approve',
          args: [contracts.LENDING_POOL, maxUint256], // Approve max to avoid multiple approvals
        });
        
        console.log('Approve transaction hash:', approveHash);
        showToast({ type: 'info', title: 'Approval submitted', message: 'Please wait for confirmation before depositing.', txHash: approveHash });
        
        // Wait for approval transaction to be confirmed
        console.log('Waiting for approval confirmation...');
        await publicClient.waitForTransactionReceipt({ hash: approveHash as `0x${string}` });
        console.log('Approval confirmed!');
      } else {
        console.log('Sufficient allowance already exists, skipping approval');
      }

      // Then deposit (using depositRWA function)
      console.log('Step 2: Depositing RWA...');
      const depositHash = await writeContractAsync({
        address: contracts.LENDING_POOL,
        abi: LENDING_POOL_ABI,
        functionName: 'depositRWA',
        args: [amount],
      });
      
      console.log('Deposit transaction hash:', depositHash);
      showToast({ type: 'success', title: 'Deposit successful', message: 'Deposit operation successful.' });
      setDepositAmount(''); // Clear input after successful transaction
    } catch (e: unknown) {
      console.error('Deposit error:', e);
      const msg = parseRevertReason(e);
      showToast({ type: 'error', title: 'Deposit failed', message: msg });
    }
  };

  const handleBorrow = async () => {
    if (!borrowAmount || parseFloat(borrowAmount) <= 0) {
      console.error('Invalid borrow amount:', borrowAmount);
      return;
    }

    if (!contracts.LENDING_POOL) {
      console.error('LendingPool contract address not configured');
      showToast({ type: 'error', message: 'LendingPool contract address not configured. Please check .env.local.' });
      return;
    }

    // Frontend limit: prevent submitting over max borrowable
    const depositBalNum = depositBalance ? Number(formatEther(depositBalance as bigint)) : 0;
    const borrowBalNum = borrowBalance ? Number(formatEther(borrowBalance as bigint)) : 0;
    const collateralValueUsd = depositBalNum * rwaPriceUsd;
    const maxBorrowUsdNum = collateralValueUsd * LTV;
    const availableBorrowUsdNum = Math.max(0, maxBorrowUsdNum - borrowBalNum);

    if (rwaPriceUsd <= 0) {
      setInlineError('Real-time price not available; cannot validate borrow limit.');
      showToast({ type: 'error', title: 'Borrow failed', message: 'Real-time price not available; cannot validate borrow limit.' });
      return;
    }
    if (parseFloat(borrowAmount) > availableBorrowUsdNum) {
      const msg = `Borrow amount exceeds your limit. Max borrowable: ${availableBorrowUsdNum.toFixed(2)} USD (limit ${maxBorrowUsdNum.toFixed(2)} − debt ${borrowBalNum.toFixed(2)}).`;
      setInlineError(msg);
      showToast({ type: 'error', title: 'Borrow limit exceeded', message: msg });
      return;
    }

    const publicClient = createPublicClient({
      transport: http(app.rpcUrl),
    });

    try {
      const amount = parseUnits(borrowAmount, 6); // MockUSD uses 6 decimals
      console.log('Starting borrow process:', { amount: borrowAmount, lendingPool: contracts.LENDING_POOL });

      // Simulate first so we 100% capture contract revert reason (no RPC/tx path can hide it)
      try {
        await publicClient.simulateContract({
          address: contracts.LENDING_POOL,
          abi: LENDING_POOL_ABI,
          functionName: 'borrowUSD',
          args: [amount],
          account: address!,
        });
      } catch (simErr: unknown) {
        // Expected when contract reverts (e.g. borrow limit exceeded); we show it in UI. Use warn so dev overlay doesn’t treat as unhandled.
        console.warn('[Borrow] Contract revert (simulation):', parseRevertReason(simErr), simErr);
        const msg = parseRevertReason(simErr);
        setInlineError(msg);
        showToast({ type: 'error', title: 'Borrow failed', message: msg });
        return;
      }

      const borrowHash = await writeContractAsync({
        address: contracts.LENDING_POOL,
        abi: LENDING_POOL_ABI,
        functionName: 'borrowUSD',
        args: [amount],
      });

      console.log('Borrow transaction hash:', borrowHash);
      setInlineError(null);
      setBorrowAmount('');
      showToast({ type: 'success', title: 'Borrow successful', message: 'Borrow operation successful.' });
    } catch (e: unknown) {
      console.error('[Borrow] Error:', e);
      const msg = parseRevertReason(e);
      setInlineError(msg);
      showToast({ type: 'error', title: 'Borrow failed', message: msg });
    }
  };

  const handleWithdraw = async () => {
    if (!rwaTokenAddress || !withdrawAmount || parseFloat(withdrawAmount) <= 0) {
      console.error('Invalid withdraw parameters:', { rwaTokenAddress, withdrawAmount });
      showToast({ type: 'info', message: 'Please enter a valid withdraw amount.' });
      return;
    }

    const depositBalNum = depositBalance ? Number(formatEther(depositBalance as bigint)) : 0;
    if (parseFloat(withdrawAmount) > depositBalNum) {
      showToast({ type: 'error', message: `Withdraw amount exceeds your Deposit Balance (current ${depositBalNum.toFixed(4)} RWA)` });
      return;
    }

    if (!contracts.LENDING_POOL) {
      console.error('LendingPool contract address not configured');
      showToast({ type: 'error', message: 'LendingPool contract address not configured. Please check .env.local.' });
      return;
    }

    try {
      const amount = parseEther(withdrawAmount);
      console.log('Starting withdraw process:', { amount: withdrawAmount, lendingPool: contracts.LENDING_POOL });
      
      if (!writeContractAsync) {
        throw new Error('writeContractAsync is not available. Please check wagmi version.');
      }
      
      const withdrawHash = await writeContractAsync({
        address: contracts.LENDING_POOL,
        abi: LENDING_POOL_ABI,
        functionName: 'withdrawRWA',
        args: [amount],
      });
      
      console.log('Withdraw transaction hash:', withdrawHash);
      setInlineError(null);
      showToast({ type: 'success', title: 'Withdraw successful', message: 'Withdraw successful.' });
      setWithdrawAmount('');
    } catch (e: unknown) {
      console.error('Withdraw error:', e);
      const msg = parseRevertReason(e);
      setInlineError(msg);
      showToast({ type: 'error', title: 'Withdraw failed', message: msg });
    }
  };

  const handleRepay = async () => {
    if (!usdTokenAddress || !repayAmount || parseFloat(repayAmount) <= 0) {
      console.error('Invalid repay parameters:', { usdTokenAddress, repayAmount });
      showToast({ type: 'info', message: 'Please enter a valid repay amount.' });
      return;
    }

    const borrowBalNum = borrowBalance ? Number(formatEther(borrowBalance as bigint)) : 0;
    if (parseFloat(repayAmount) > borrowBalNum) {
      showToast({ type: 'error', message: `Repay amount cannot exceed Borrow Balance (current debt ${borrowBalNum.toFixed(4)} USD).` });
      return;
    }

    if (!contracts.LENDING_POOL) {
      console.error('LendingPool contract address not configured');
      showToast({ type: 'error', message: 'LendingPool contract address not configured. Please check .env.local.' });
      return;
    }

    try {
      const amount = parseUnits(repayAmount, 6); // MockUSD uses 6 decimals
      console.log('Starting repay process:', { amount: repayAmount, usdTokenAddress, lendingPool: contracts.LENDING_POOL });
      
      if (!writeContractAsync) {
        throw new Error('writeContractAsync is not available. Please check wagmi version.');
      }
      
      // First approve USD token
      console.log('Step 1: Approving USD token...');
      const approveHash = await writeContractAsync({
        address: usdTokenAddress,
        abi: [
          {
            inputs: [
              { name: 'spender', type: 'address' },
              { name: 'amount', type: 'uint256' },
            ],
            name: 'approve',
            outputs: [{ name: '', type: 'bool' }],
            stateMutability: 'nonpayable',
            type: 'function',
          },
        ],
        functionName: 'approve',
        args: [contracts.LENDING_POOL, amount],
      });
      
      console.log('Approve transaction hash:', approveHash);
      showToast({ type: 'info', title: 'Approval submitted', message: 'Approval submitted.' });
      
      // Wait for approval to be confirmed
      console.log('Waiting for approval confirmation...');
      await new Promise(resolve => setTimeout(resolve, 5000));

      // Then repay (using repayUSD function)
      console.log('Step 2: Repaying USD...');
      const repayHash = await writeContractAsync({
        address: contracts.LENDING_POOL,
        abi: LENDING_POOL_ABI,
        functionName: 'repayUSD',
        args: [amount],
      });
      
      console.log('Repay transaction hash:', repayHash);
      setInlineError(null);
      showToast({ type: 'success', title: 'Repay successful', message: 'Repay successful.' });
      setRepayAmount(''); // Clear input after successful transaction
    } catch (e: unknown) {
      console.error('Repay error:', e);
      const msg = parseRevertReason(e);
      setInlineError(msg);
      showToast({ type: 'error', title: 'Repay failed', message: msg });
    }
  };

  if (!mounted) {
    return (
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700 animate-pulse">
        <div className="h-6 bg-gray-200 dark:bg-gray-700 rounded w-1/4 mb-4"></div>
      </div>
    );
  }

  if (!address) {
    return (
      <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
        <p className="text-center text-gray-500">Please connect your wallet to use lending features</p>
      </div>
    );
  }

  const depositBal = depositBalance ? Number(formatEther(depositBalance as bigint)) : 0;
  const borrowBal = borrowBalance ? Number(formatEther(borrowBalance as bigint)) : 0;
  const rwaBal = rwaBalance ? Number(formatEther(rwaBalance as bigint)) : 0;
  const usdBal = usdBalance ? Number(formatUnits(usdBalance as bigint, 6)) : 0; // USD uses 6 decimals
  const collateralValueUsd = depositBal * rwaPriceUsd;
  const maxBorrowUsd = collateralValueUsd * LTV;
  const availableBorrowUsd = Math.max(0, maxBorrowUsd - borrowBal); // Available to borrow = limit minus current debt / 可借额度 = 上限 - 已借

  // Format health factor (handle max value for no debt)
  const formatHealthFactor = (hf: bigint | undefined): string => {
    if (!hf) return 'N/A';
    // Check if it's the max value (no debt)
    if (hf === BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff')) {
      return '∞ (Safe)';
    }
    const hfNumber = Number(formatEther(hf));
    if (hfNumber > 1e10) return '∞ (Safe)'; // Very large number means no debt
    return hfNumber.toFixed(4);
  };
  
  const hf = healthFactor ? Number(formatEther(healthFactor as bigint)) : 0;
  const hfDisplay = formatHealthFactor(healthFactor as bigint | undefined);

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
      {/* Toast in portal so it's always on top (avoids stacking/overflow issues) / 用 Portal 挂到 body 保证在最上层 */}
      {typeof document !== 'undefined' && createPortal(
        <ToastModal state={toast} onClose={closeToast} />,
        document.body
      )}
      {/* Inline error banner so user always sees failure reason even if modal is missed / 内联错误条 */}
      {inlineError && (
        <div
          role="alert"
          className="mb-4 flex items-start gap-3 rounded-lg border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-900/20 p-4 text-red-800 dark:text-red-200"
        >
          <span className="shrink-0 text-lg" aria-hidden>⚠</span>
          <p className="flex-1 min-w-0 text-sm font-medium break-words">{inlineError}</p>
          <button
            type="button"
            onClick={() => setInlineError(null)}
            className="shrink-0 rounded px-2 py-1 text-xs font-medium bg-red-200 dark:bg-red-800 hover:bg-red-300 dark:hover:bg-red-700"
          >
            Dismiss
          </button>
        </div>
      )}
      <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-6">
        Lending & Borrowing
        <span className="ml-3 inline-flex items-center rounded-full bg-amber-100 dark:bg-amber-900/40 px-3 py-1 text-sm font-medium text-amber-800 dark:text-amber-200 ring-1 ring-amber-600/20">
          Single stock per contract (currently NVDA)
        </span>
      </h2>

      {/* Tabs */}
      <div className="flex space-x-2 mb-6 border-b border-gray-200 dark:border-gray-700">
        {(['deposit', 'borrow', 'withdraw', 'repay'] as const).map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            className={`px-4 py-2 font-medium capitalize ${
              activeTab === tab
                ? 'text-blue-600 dark:text-blue-400 border-b-2 border-blue-600 dark:border-blue-400'
                : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300'
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      {/* Status Cards */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">Deposit Balance</p>
          <p className="text-lg font-semibold text-gray-900 dark:text-white">{depositBal.toFixed(4)} RWA</p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">Borrow Balance</p>
          <p className="text-lg font-semibold text-gray-900 dark:text-white">{borrowBal.toFixed(4)} USD</p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">Health Factor</p>
          <p className={`text-lg font-semibold ${
            hfDisplay.includes('∞') ? 'text-green-600' :
            hf < 1.0 ? 'text-red-600' : 
            hf < 1.5 ? 'text-yellow-600' : 
            'text-green-600'
          }`}>
            {hfDisplay}
          </p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
          <p className="text-sm text-gray-600 dark:text-gray-400">RWA Balance</p>
          <p className="text-lg font-semibold text-gray-900 dark:text-white">{rwaBal.toFixed(4)} RWA</p>
        </div>
      </div>

      {/* Deposit Tab */}
      {activeTab === 'deposit' && (
        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Deposit Amount (RWA)
            </label>
            <div className="flex space-x-2">
              <input
                type="number"
                value={depositAmount}
                onChange={(e) => setDepositAmount(e.target.value)}
                placeholder="0.0"
                className="flex-1 px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
              />
              <button
                onClick={() => setDepositAmount(rwaBal.toString())}
                className="px-4 py-2 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-600"
              >
                Max
              </button>
            </div>
            <p className="mt-1 text-sm text-gray-500">Available: {rwaBal.toFixed(4)} RWA</p>
            {rwaBal === 0 && (
              <p className="mt-1 text-sm text-amber-600 dark:text-amber-400">
                No RWA in wallet. RWA is minted only by the contract owner—request testnet RWA from the deployer.
              </p>
            )}
          </div>
          <button
            onClick={handleDeposit}
            disabled={isPending || isConfirming || !depositAmount || parseFloat(depositAmount) <= 0 || parseFloat(depositAmount) > rwaBal}
            className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed"
          >
            {isPending || isConfirming ? 'Processing...' : 'Deposit'}
          </button>
        </div>
      )}

      {/* Borrow Tab */}
      {activeTab === 'borrow' && (
        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Borrow Amount (USD)
            </label>
            <input
              type="number"
              value={borrowAmount}
              onChange={(e) => setBorrowAmount(e.target.value)}
              placeholder="0.0"
              className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
            />
            <p className="mt-1 text-sm text-gray-500">
              Max borrowable: {depositBal > 0 && rwaPriceUsd > 0 ? availableBorrowUsd.toFixed(2) : '0.00'} USD (limit {maxBorrowUsd.toFixed(2)} − debt {borrowBal.toFixed(2)})
            </p>
            <p className="mt-0.5 text-xs text-gray-400">
              Limit = Deposit Balance × RWA price × 70% LTV. Your collateral value: {depositBal > 0 && rwaPriceUsd > 0 ? `$${(depositBal * rwaPriceUsd).toFixed(2)}` : '$0.00'} ({depositBal.toFixed(4)} RWA × ${rwaPriceUsd.toFixed(2)}).
            </p>
            {borrowAmount && rwaPriceUsd > 0 && parseFloat(borrowAmount) > availableBorrowUsd && (
              <p className="mt-2 text-sm text-red-600 dark:text-red-400 font-medium">
                Amount exceeds your borrow limit (max {availableBorrowUsd.toFixed(2)} USD).
              </p>
            )}
          </div>
          <button
            onClick={handleBorrow}
            disabled={isPending || isConfirming || !borrowAmount || parseFloat(borrowAmount) <= 0 || (rwaPriceUsd > 0 && parseFloat(borrowAmount) > availableBorrowUsd)}
            className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed"
          >
            {isPending || isConfirming ? 'Processing...' : 'Borrow'}
          </button>
        </div>
      )}

      {/* Withdraw Tab */}
      {activeTab === 'withdraw' && (
        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Withdraw Amount (RWA)
            </label>
            <div className="flex space-x-2">
              <input
                type="number"
                value={withdrawAmount}
                onChange={(e) => setWithdrawAmount(e.target.value)}
                placeholder="0.0"
                className="flex-1 px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
              />
              <button
                onClick={() => setWithdrawAmount(depositBal.toString())}
                className="px-4 py-2 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-600"
              >
                Max
              </button>
            </div>
            <p className="mt-1 text-sm text-gray-500">Deposited: {depositBal.toFixed(4)} RWA</p>
          </div>
          <button
            onClick={handleWithdraw}
            disabled={isPending || isConfirming || !withdrawAmount || parseFloat(withdrawAmount) <= 0 || parseFloat(withdrawAmount) > depositBal}
            className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed"
          >
            {isPending || isConfirming ? 'Processing...' : 'Withdraw'}
          </button>
        </div>
      )}

      {/* Repay Tab */}
      {activeTab === 'repay' && (
        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Repay Amount (USD)
            </label>
            <div className="flex space-x-2">
              <input
                type="number"
                value={repayAmount}
                onChange={(e) => setRepayAmount(e.target.value)}
                placeholder="0.0"
                className="flex-1 px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
              />
              <button
                onClick={() => setRepayAmount(Math.min(borrowBal, usdBal).toString())}
                className="px-4 py-2 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-200 dark:hover:bg-gray-600"
              >
                Max
              </button>
            </div>
            <p className="mt-1 text-sm text-gray-500">
              Borrowed: {borrowBal.toFixed(4)} USD | Available: {usdBal.toFixed(4)} USD
            </p>
          </div>
          <button
            onClick={handleRepay}
            disabled={isPending || isConfirming || !repayAmount || parseFloat(repayAmount) <= 0 || parseFloat(repayAmount) > borrowBal}
            className="w-full px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed"
          >
            {isPending || isConfirming ? 'Processing...' : 'Repay'}
          </button>
        </div>
      )}

      {/* Transaction Status */}
      {writeError && (
        <div className="mt-4 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded">
          <p className="text-sm text-red-800 dark:text-red-200">Error: {writeError.message}</p>
        </div>
      )}

      {isConfirmed && (
        <div className="mt-4 p-3 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded">
          <p className="text-sm text-green-800 dark:text-green-200">Transaction confirmed!</p>
        </div>
      )}
    </div>
  );
}
