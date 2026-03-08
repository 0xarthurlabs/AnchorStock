'use client';

import { useState, useEffect } from 'react';

/**
 * Renders children only after client mount. Use to avoid hydration mismatch when
 * browser extensions (e.g. Baidu input) inject attributes (e.g. bis_skin_checked) into the DOM.
 * Server and first client paint: single placeholder div with suppressHydrationWarning.
 * After mount: full app tree (no hydration of that tree).
 * 仅在客户端挂载后渲染子节点，用于避免浏览器扩展注入属性导致的水合不一致。
 */
export function ClientOnly({ children }: { children: React.ReactNode }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  if (!mounted) {
    return (
      <div
        className="min-h-screen bg-gray-50 dark:bg-gray-900 flex items-center justify-center antialiased"
        suppressHydrationWarning
      >
        <span className="text-gray-500">Loading...</span>
      </div>
    );
  }

  return <>{children}</>;
}
