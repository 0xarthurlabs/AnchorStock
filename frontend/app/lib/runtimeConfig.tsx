'use client';

import React, { createContext, useContext, useEffect, useMemo, useState } from 'react';
import type { AppConfig } from './appConfig';
import { getBuildtimeAppConfig } from './appConfig';
import type { ContractAddresses } from './contracts';
import { getBuildtimeContracts, loadContractsFromDeployments } from './contracts';

export type RuntimeConfigState = {
  app: AppConfig;
  contracts: ContractAddresses;
  source: 'deployments' | 'env';
};

const Ctx = createContext<RuntimeConfigState | null>(null);

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

async function sha256Text(s: string): Promise<string> {
  const data = new TextEncoder().encode(s);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return hex(digest);
}

export function RuntimeConfigProvider({ children }: { children: React.ReactNode }) {
  const app = useMemo(() => getBuildtimeAppConfig(), []);
  const [state, setState] = useState<RuntimeConfigState>(() => ({
    app,
    contracts: getBuildtimeContracts(),
    source: 'env',
  }));

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        // Optional anti-tamper: pipeline can inject SHA256 for the exact artifact content.
        // Format: lowercase hex of sha256(jsonText)
        const expected = process.env.NEXT_PUBLIC_DEPLOYMENTS_SHA256?.trim().toLowerCase();
        if (expected) {
          const url = `/deployments/${app.env}/${app.chainId}.json`;
          const res = await fetch(url, { cache: 'no-store' });
          if (!res.ok) throw new Error(`Failed to load deployments artifact: ${url} (${res.status})`);
          const text = await res.text();
          const got = await sha256Text(text);
          if (got !== expected) {
            throw new Error(`Deployments artifact integrity check failed for ${url} (sha256 mismatch)`);
          }
          // Parse & validate after integrity pass
          const parsed = JSON.parse(text) as unknown;
          // Reuse existing loader validation by temporarily stashing into fetch path is messy;
          // instead just call loader after this check (it will refetch). Small cost, clear logic.
        }

        const c = await loadContractsFromDeployments({ env: app.env, chainId: app.chainId });
        if (!cancelled) setState({ app, contracts: c, source: 'deployments' });
      } catch (e) {
        // Fall back to build-time env injection (方式 A). Keep error visible for debugging.
        console.warn('[config] deployments artifact unavailable; falling back to NEXT_PUBLIC_*', e);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [app]);

  return <Ctx.Provider value={state}>{children}</Ctx.Provider>;
}

export function useRuntimeConfig(): RuntimeConfigState {
  const v = useContext(Ctx);
  if (!v) throw new Error('useRuntimeConfig must be used within RuntimeConfigProvider');
  return v;
}

