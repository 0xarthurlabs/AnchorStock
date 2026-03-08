// Contract addresses (from environment variables) / 合约地址（来自环境变量）
// Helper function to safely get contract address / 安全获取合约地址的辅助函数
function getContractAddress(envVar: string | undefined): `0x${string}` | undefined {
  if (!envVar || envVar === '0x...' || envVar === '') return undefined;
  return envVar as `0x${string}`;
}

export const CONTRACTS = {
  ORACLE: getContractAddress(process.env.NEXT_PUBLIC_ORACLE_CONTRACT_ADDRESS),
  LENDING_POOL: getContractAddress(process.env.NEXT_PUBLIC_LENDING_POOL_CONTRACT_ADDRESS),
  PERP_ENGINE: getContractAddress(process.env.NEXT_PUBLIC_PERP_ENGINE_CONTRACT_ADDRESS),
  RWA_TOKEN: getContractAddress(process.env.NEXT_PUBLIC_RWA_TOKEN_CONTRACT_ADDRESS),
  USD_TOKEN: getContractAddress(process.env.NEXT_PUBLIC_USD_TOKEN_CONTRACT_ADDRESS),
  /** aToken address (collateral for PerpEngine). Optional; can be derived from LendingPool.aTokens(RWA_TOKEN). */
  A_TOKEN: getContractAddress(process.env.NEXT_PUBLIC_A_TOKEN_CONTRACT_ADDRESS),
} as const;

// Contract ABIs (simplified, should be imported from compiled contracts) / 合约 ABI（简化版，应从编译后的合约导入）
export const ORACLE_ABI = [
  {
    inputs: [{ name: 'symbol', type: 'string' }],
    name: 'getPrice',
    outputs: [
      { name: 'normalizedPrice', type: 'uint256' },
      { name: 'timestamp', type: 'uint256' },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ name: 'symbol', type: 'string' }],
    name: 'isPriceStale',
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'oracleStrategy',
    outputs: [{ name: '', type: 'uint8' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const;

export const LENDING_POOL_ABI = [
  {
    inputs: [{ name: 'user', type: 'address' }],
    name: 'getAccountHealthFactor',
    outputs: [{ name: 'healthFactor', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      { name: 'user', type: 'address' },
      { name: 'asset', type: 'address' },
    ],
    name: 'deposits',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ name: 'user', type: 'address' }],
    name: 'borrows',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ name: 'amount', type: 'uint256' }],
    name: 'depositRWA',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ name: 'amount', type: 'uint256' }],
    name: 'withdrawRWA',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ name: 'amount', type: 'uint256' }],
    name: 'borrowUSD',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ name: 'amount', type: 'uint256' }],
    name: 'repayUSD',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ name: 'asset', type: 'address' }],
    name: 'aTokens',
    outputs: [{ name: '', type: 'address' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const;

export const PERP_ENGINE_ABI = [
  {
    inputs: [{ name: 'user', type: 'address' }],
    name: 'getPositionHealthFactor',
    outputs: [{ name: 'healthFactor', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'collateralToken',
    outputs: [{ name: '', type: 'address' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ name: 'user', type: 'address' }],
    name: 'positions',
    outputs: [
      { name: 'side', type: 'uint8' },
      { name: 'size', type: 'uint256' },
      { name: 'entryPrice', type: 'uint256' },
      { name: 'collateral', type: 'uint256' },
      { name: 'entryTimestamp', type: 'uint256' },
      { name: 'lastFundingTimestamp', type: 'uint256' },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [
      { name: 'side', type: 'uint8' },
      { name: 'size', type: 'uint256' },
      { name: 'collateralAmount', type: 'uint256' },
    ],
    name: 'openPosition',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ name: 'size', type: 'uint256' }],
    name: 'closePosition',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ name: 'amount', type: 'uint256' }],
    name: 'addCollateral',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ name: 'amount', type: 'uint256' }],
    name: 'withdrawCollateral',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
] as const;
