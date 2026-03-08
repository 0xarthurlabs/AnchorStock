import { getDefaultConfig } from '@rainbow-me/rainbowkit';
import { http } from 'wagmi';
import { defineChain } from 'viem';

// Define Sei Testnet chain
const seiTestnet = defineChain({
  id: 1328,
  name: 'Sei Testnet',
  nativeCurrency: {
    decimals: 18,
    name: 'Sei',
    symbol: 'SEI',
  },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_RPC_URL || 'https://sei-testnet.g.alchemy.com/v2/kwGPlgLKnCNFMJyExjnfS6ZaODRRBD-P'],
    },
  },
  blockExplorers: {
    default: {
      name: 'SeiTrace',
      url: 'https://atlantic-2-api.seitrace.com',
    },
  },
  testnet: true,
});

// Get RPC URL from environment variable
const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL || 'https://sei-testnet.g.alchemy.com/v2/kwGPlgLKnCNFMJyExjnfS6ZaODRRBD-P';

// Use Sei Testnet as default chain
const chains = [seiTestnet];

// Create Wagmi config
export const config = getDefaultConfig({
  appName: 'AnchorStock',
  projectId: process.env.NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID || 'your-project-id',
  chains: chains,
  transports: {
    [seiTestnet.id]: http(rpcUrl),
  },
  ssr: true, // Enable SSR
});
