export type AppEnv = 'dev' | 'staging' | 'prod';

export type AppConfig = {
  env: AppEnv;
  chainId: number;
  rpcUrl: string;
  backendApiUrl: string;
  /** Comma-separated allowlist of RPC origins for CSP + runtime validation. */
  rpcOriginAllowlist: string[];
};

function required(name: string, v: string | undefined): string {
  if (v == null || v.trim() === '') throw new Error(`Missing required env var: ${name}`);
  return v.trim();
}

function optionalCsv(v: string | undefined): string[] {
  if (!v) return [];
  return v
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

export function parseOrigin(url: string): string {
  const u = new URL(url);
  return u.origin;
}

export function getBuildtimeAppEnv(): AppEnv {
  const raw = process.env.NEXT_PUBLIC_APP_ENV?.trim();
  if (raw === 'dev' || raw === 'staging' || raw === 'prod') return raw;
  // Local dev convenience; staging/prod must be explicit to avoid accidental mixing.
  if (process.env.NODE_ENV === 'development') return 'dev';
  throw new Error(
    `NEXT_PUBLIC_APP_ENV must be set to dev|staging|prod for non-dev builds (got: ${raw ?? 'undefined'})`,
  );
}

export function getBuildtimeAppConfig(): AppConfig {
  const env = getBuildtimeAppEnv();
  const chainId = Number(required('NEXT_PUBLIC_CHAIN_ID', process.env.NEXT_PUBLIC_CHAIN_ID));
  if (!Number.isFinite(chainId) || chainId <= 0) throw new Error(`Invalid NEXT_PUBLIC_CHAIN_ID: ${process.env.NEXT_PUBLIC_CHAIN_ID}`);

  const rpcUrl = required('NEXT_PUBLIC_RPC_URL', process.env.NEXT_PUBLIC_RPC_URL);
  const backendApiUrl = process.env.NEXT_PUBLIC_BACKEND_API_URL?.trim() || 'http://localhost:3001';

  const allowlist = optionalCsv(process.env.NEXT_PUBLIC_RPC_ORIGIN_ALLOWLIST);
  const rpcOrigin = parseOrigin(rpcUrl);
  const rpcOriginAllowlist = allowlist.length > 0 ? allowlist : [rpcOrigin];

  // Hard safety rails: prod must not accidentally point to non-allowlisted origin.
  if ((env === 'prod' || env === 'staging') && !rpcOriginAllowlist.includes(rpcOrigin)) {
    throw new Error(
      `RPC origin (${rpcOrigin}) not in NEXT_PUBLIC_RPC_ORIGIN_ALLOWLIST for ${env}. Refusing to start.`,
    );
  }

  return { env, chainId, rpcUrl, backendApiUrl, rpcOriginAllowlist };
}

export function getDefaultConnectSrcAllowlist(cfg: AppConfig): string[] {
  const rpcOrigin = parseOrigin(cfg.rpcUrl);
  const backendOrigin = (() => {
    try {
      return parseOrigin(cfg.backendApiUrl);
    } catch {
      return undefined;
    }
  })();

  const common = [
    "'self'",
    rpcOrigin,
    ...cfg.rpcOriginAllowlist,
    backendOrigin,
    // WalletConnect / RainbowKit common endpoints (public, non-secret)
    'https://rpc.walletconnect.com',
    'https://relay.walletconnect.com',
    'wss://relay.walletconnect.com',
    'https://api.web3modal.org',
    'https://explorer-api.walletconnect.com',
  ].filter(Boolean) as string[];

  // Deduplicate while keeping order
  return Array.from(new Set(common));
}

