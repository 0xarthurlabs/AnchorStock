import type { NextConfig } from "next";
import { getDefaultConnectSrcAllowlist, getBuildtimeAppConfig } from "./app/lib/appConfig";

function buildCsp(): string {
  const cfg = getBuildtimeAppConfig();
  const connectSrc = getDefaultConnectSrcAllowlist(cfg).join(' ');
  // Minimal CSP baseline; extend as needed when adding external scripts/images/fonts.
  return [
    `default-src 'self'`,
    `base-uri 'self'`,
    `frame-ancestors 'none'`,
    `object-src 'none'`,
    `form-action 'self'`,
    `img-src 'self' data: https:`,
    `style-src 'self' 'unsafe-inline'`,
    `script-src 'self' 'unsafe-eval' 'unsafe-inline'`,
    `connect-src ${connectSrc}`,
  ].join('; ');
}

const nextConfig: NextConfig = {
  output: "standalone",
  async headers() {
    const csp = buildCsp();
    return [
      {
        source: "/(.*)",
        headers: [
          { key: "Content-Security-Policy", value: csp },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
        ],
      },
    ];
  },
};

export default nextConfig;
