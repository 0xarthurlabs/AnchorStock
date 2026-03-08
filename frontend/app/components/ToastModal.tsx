'use client';

import { useState, useCallback } from 'react';

export type ToastType = 'success' | 'error' | 'info';

export interface ToastState {
  open: boolean;
  type: ToastType;
  title?: string;
  message: string;
  txHash?: string;
}

const typeStyles = {
  success: {
    icon: '✓',
    bg: 'bg-emerald-50 dark:bg-emerald-900/20',
    border: 'border-emerald-200 dark:border-emerald-800',
    iconBg: 'bg-emerald-500',
    title: 'text-emerald-800 dark:text-emerald-200',
    button: 'bg-emerald-600 hover:bg-emerald-700 text-white',
  },
  error: {
    icon: '✕',
    bg: 'bg-red-50 dark:bg-red-900/20',
    border: 'border-red-200 dark:border-red-800',
    iconBg: 'bg-red-500',
    title: 'text-red-800 dark:text-red-200',
    button: 'bg-red-600 hover:bg-red-700 text-white',
  },
  info: {
    icon: 'ℹ',
    bg: 'bg-sky-50 dark:bg-sky-900/20',
    border: 'border-sky-200 dark:border-sky-800',
    iconBg: 'bg-sky-500',
    title: 'text-sky-800 dark:text-sky-200',
    button: 'bg-sky-600 hover:bg-sky-700 text-white',
  },
};

interface ToastModalProps {
  state: ToastState;
  onClose: () => void;
}

export function ToastModal({ state, onClose }: ToastModalProps) {
  const [copied, setCopied] = useState(false);
  const { open, type, title, message, txHash } = state;
  const style = typeStyles[type];

  const copyTxHash = useCallback(() => {
    if (!txHash) return;
    navigator.clipboard.writeText(txHash).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  }, [txHash]);

  if (!open) return null;

  const defaultTitle = type === 'success' ? 'Success' : type === 'error' ? 'Error' : 'Info';

  return (
    <>
      <div
        className="fixed inset-0 z-50 bg-black/40 backdrop-blur-sm transition-opacity"
        onClick={onClose}
        aria-hidden
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="toast-title"
        className={`fixed left-1/2 top-1/2 z-50 w-[min(90vw,400px)] -translate-x-1/2 -translate-y-1/2 rounded-2xl border shadow-xl ${style.bg} ${style.border}`}
      >
        <div className="p-5">
          <div className="flex items-start gap-4">
            <span
              className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-full ${style.iconBg} text-white text-lg font-medium`}
            >
              {style.icon}
            </span>
            <div className="min-w-0 flex-1">
              <h3 id="toast-title" className={`font-semibold ${style.title}`}>
                {title ?? defaultTitle}
              </h3>
              <p className="mt-1 text-sm text-gray-700 dark:text-gray-300 whitespace-pre-wrap break-words">
                {message}
              </p>
              {txHash && (
                <div className="mt-3 flex items-center gap-2">
                  <code className="flex-1 truncate rounded bg-black/5 dark:bg-white/10 px-2 py-1.5 text-xs text-gray-600 dark:text-gray-400">
                    {txHash}
                  </code>
                  <button
                    type="button"
                    onClick={(e) => { e.stopPropagation(); copyTxHash(); }}
                    className="shrink-0 rounded-lg bg-gray-200 dark:bg-gray-600 px-3 py-1.5 text-xs font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-300 dark:hover:bg-gray-500"
                  >
                    {copied ? 'Copied' : 'Copy'}
                  </button>
                </div>
              )}
            </div>
          </div>
          <div className="mt-5 flex justify-end">
            <button
              type="button"
              onClick={onClose}
              className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${style.button}`}
            >
               Close
            </button>
          </div>
        </div>
      </div>
    </>
  );
}
