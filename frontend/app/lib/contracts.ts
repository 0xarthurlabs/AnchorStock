export type ContractAddresses = {
  ORACLE?: `0x${string}`;
  LENDING_POOL?: `0x${string}`;
  PERP_ENGINE?: `0x${string}`;
  RWA_TOKEN?: `0x${string}`;
  USD_TOKEN?: `0x${string}`;
  A_TOKEN?: `0x${string}`;
};

function asAddress(v: unknown): `0x${string}` | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.trim();
  if (!s || s === '0x...' || s === '0x0000000000000000000000000000000000000000') return undefined;
  if (!/^0x[0-9a-fA-F]{40}$/.test(s)) return undefined;
  return s as `0x${string}`;
}

export function getBuildtimeContracts(): ContractAddresses {
  return {
    ORACLE: asAddress(process.env.NEXT_PUBLIC_ORACLE_CONTRACT_ADDRESS),
    LENDING_POOL: asAddress(process.env.NEXT_PUBLIC_LENDING_POOL_CONTRACT_ADDRESS),
    PERP_ENGINE: asAddress(process.env.NEXT_PUBLIC_PERP_ENGINE_CONTRACT_ADDRESS),
    RWA_TOKEN: asAddress(process.env.NEXT_PUBLIC_RWA_TOKEN_CONTRACT_ADDRESS),
    USD_TOKEN: asAddress(process.env.NEXT_PUBLIC_USD_TOKEN_CONTRACT_ADDRESS),
    A_TOKEN: asAddress(process.env.NEXT_PUBLIC_A_TOKEN_CONTRACT_ADDRESS),
  } as const;
}

export type DeploymentsJson = Partial<{
  ORACLE: string;
  LENDING_POOL: string;
  PERP_ENGINE: string;
  RWA_TOKEN: string;
  USD_TOKEN: string;
  A_TOKEN: string;
}>;

export async function loadContractsFromDeployments(opts: {
  env: 'dev' | 'staging' | 'prod';
  chainId: number;
}): Promise<ContractAddresses> {
  // Same-origin public artifact; must be provided by release pipeline.
  const url = `/deployments/${opts.env}/${opts.chainId}.json`;
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error(`Failed to load deployments artifact: ${url} (${res.status})`);
  const json = (await res.json()) as DeploymentsJson & Partial<{ chainId: number; env: string }>;
  if (typeof json.chainId === 'number' && json.chainId !== opts.chainId) {
    throw new Error(`Deployments artifact chainId mismatch: expected ${opts.chainId}, got ${json.chainId}`);
  }
  if (typeof json.env === 'string' && json.env && json.env !== opts.env) {
    throw new Error(`Deployments artifact env mismatch: expected ${opts.env}, got ${json.env}`);
  }
  return {
    ORACLE: asAddress(json.ORACLE),
    LENDING_POOL: asAddress(json.LENDING_POOL),
    PERP_ENGINE: asAddress(json.PERP_ENGINE),
    RWA_TOKEN: asAddress(json.RWA_TOKEN),
    USD_TOKEN: asAddress(json.USD_TOKEN),
    A_TOKEN: asAddress(json.A_TOKEN),
  };
}

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
