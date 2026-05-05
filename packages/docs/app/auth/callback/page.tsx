"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { HappyViewBrowserClient } from "@happyview/oauth-client-browser";

export default function AuthCallbackPage() {
  const router = useRouter();
  const handled = useRef(false);

  useEffect(() => {
    if (handled.current) return;
    handled.current = true;

    const happyviewUrl = process.env.NEXT_PUBLIC_HAPPYVIEW_URL || window.location.origin;
    const isLoopback = window.location.hostname === "localhost";
    const clientId = isLoopback
      ? "http://localhost?scope=atproto"
      : `${window.location.origin}/oauth-client-metadata.json`;
    const client = new HappyViewBrowserClient({
      instanceUrl: happyviewUrl,
      clientId,
      clientKey: process.env.NEXT_PUBLIC_CLIENT_KEY!,
      redirectUri: `${window.location.origin}/auth/callback`,
      fetch: ((input: RequestInfo | URL, init?: RequestInit) => window.fetch(input, init)) as typeof fetch,
    });

    client
      .callback(window.location.search)
      .then(() => router.replace("/dashboard"))
      .catch((err) => {
        console.error("OAuth callback failed:", err);
        router.replace("/");
      });
  }, [router]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-bg text-fg">
      <p className="font-mono text-sm text-fg-muted">Signing in…</p>
    </div>
  );
}
