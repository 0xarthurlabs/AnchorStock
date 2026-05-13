'use client';

import { useState, useEffect } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { RainbowKitProvider } from '@rainbow-me/rainbowkit';
import { createWagmiConfig } from './lib/wagmi';
import { RuntimeConfigProvider, useRuntimeConfig } from './lib/runtimeConfig';
import { getBuildtimeAppConfig } from './lib/appConfig';
import '@rainbow-me/rainbowkit/styles.css';

// Create QueryClient inside component to avoid sharing between requests
function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 60 * 1000, // 1 minute
      },
    },
  });
}

let browserQueryClient: QueryClient | undefined = undefined;

function getQueryClient() {
  // Always check if we're in the browser environment
  if (typeof window === 'undefined') {
    // Server: always make a new query client
    return makeQueryClient();
  }
  // Browser: use singleton pattern to keep the same query client
  if (!browserQueryClient) {
    browserQueryClient = makeQueryClient();
  }
  return browserQueryClient;
}

export function Providers({ children }: { children: React.ReactNode }) {
  // Use state to ensure QueryClient is only created once on the client
  const [queryClient] = useState(() => getQueryClient());
  const [wagmiConfig] = useState(() => createWagmiConfig(getBuildtimeAppConfig()));

  // Catch unhandled MetaMask connect rejections to avoid full-page error / 捕获 MetaMask 连接失败等未处理的 Promise rejection，避免整页报错
  useEffect(() => {
    const onRejection = (e: PromiseRejectionEvent) => {
      const msg = e?.reason?.message ?? String(e?.reason ?? '');
      if (msg.includes('Failed to connect to MetaMask') || msg.includes('connect to MetaMask') || /metamask/i.test(msg)) {
        e.preventDefault();
        console.warn('Wallet connect failed:', msg);
        if (typeof window !== 'undefined' && window.alert) {
          window.alert('Failed to connect to MetaMask. Please ensure: 1) MetaMask is installed and unlocked; 2) Click "Connect" in the popup.');
        }
      }
    };
    window.addEventListener('unhandledrejection', onRejection);
    return () => window.removeEventListener('unhandledrejection', onRejection);
  }, []);

  return (
    <RuntimeConfigProvider>
      <WagmiProvider config={wagmiConfig}>
        <QueryClientProvider client={queryClient}>
          <RainbowKitProvider>{children}</RainbowKitProvider>
        </QueryClientProvider>
      </WagmiProvider>
    </RuntimeConfigProvider>
  );
}
