'use client';

import { useEffect } from 'react';

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  const isMetaMaskConnect = error?.message?.includes('Failed to connect to MetaMask') ||
    error?.message?.includes('connect to MetaMask') ||
    error?.message?.toLowerCase().includes('metamask');

  return (
    <div className="min-h-[40vh] flex items-center justify-center p-6">
      <div className="max-w-md w-full bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 p-6 shadow-lg">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
          {isMetaMaskConnect ? 'Failed to connect to MetaMask' : 'Something went wrong'}
        </h2>
        <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
          {isMetaMaskConnect ? (
            <>
              Please check: 1) MetaMask extension is installed; 2) MetaMask is unlocked and an account is selected; 3) Click &quot;Connect&quot; in the popup to authorize this site. If it still fails after authorizing, refresh the page and try again.
            </>
          ) : (
            error?.message || 'Unknown error'
          )}
        </p>
        <div className="flex gap-3">
          <button
            type="button"
            onClick={reset}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 text-sm font-medium"
          >
            {isMetaMaskConnect ? 'Retry connect' : 'Retry'}
          </button>
          <button
            type="button"
            onClick={() => window.location.href = '/'}
            className="px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 text-sm font-medium"
          >
            Back to home
          </button>
        </div>
      </div>
    </div>
  );
}
