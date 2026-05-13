import { getDefaultConfig } from '@rainbow-me/rainbowkit';
import { http } from 'wagmi';
import { defineChain } from 'viem';
import type { AppConfig } from './appConfig';

export function createWagmiConfig(app: AppConfig) {
  const chain = defineChain({
    id: app.chainId,
    name: app.env === 'prod' ? `AnchorStock Mainnet (${app.chainId})` : `AnchorStock ${app.env} (${app.chainId})`,
    nativeCurrency: { decimals: 18, name: 'Native', symbol: 'NATIVE' },
    rpcUrls: { default: { http: [app.rpcUrl] } },
    blockExplorers: {
      default: {
        name: 'Explorer',
        url: 'https://example.com',
      },
    },
    testnet: app.env !== 'prod',
  });

  const chains = [chain] as const; // RainbowKit 要求 tuple 形态
  return getDefaultConfig({
    appName: 'AnchorStock',
    projectId: process.env.NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID || 'your-project-id',
    chains,
    transports: {
      [chain.id]: http(app.rpcUrl),
    },
    ssr: true,
  });
}
