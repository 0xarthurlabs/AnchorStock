'use client';

import { useEffect, useState } from 'react';
import { ConnectButton } from '@rainbow-me/rainbowkit';

export function Header() {
  const [mounted, setMounted] = useState(false);

  // Prevent hydration mismatch by only rendering ConnectButton on client
  // 仅在客户端渲染 ConnectButton，防止水合不匹配
  useEffect(() => {
    setMounted(true);
  }, []);

  return (
    <header className="bg-white dark:bg-gray-900 border-b border-gray-200 dark:border-gray-700">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between items-center h-16">
          <div className="flex items-center">
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white">
              AnchorStock
            </h1>
            <span className="ml-2 text-sm text-gray-500 dark:text-gray-400">
              US Stock RWA DeFi
            </span>
          </div>
          {mounted ? <ConnectButton /> : <div className="h-10 w-32" />}
        </div>
      </div>
    </header>
  );
}
