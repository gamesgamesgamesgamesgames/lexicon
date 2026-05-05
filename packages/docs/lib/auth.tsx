"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { HappyViewBrowserClient, type HappyViewSession } from "@happyview/oauth-client-browser";

function patchSession(session: HappyViewSession) {
  // Fix "Illegal invocation" — detached native fetch
  (session as any)._fetch = (input: RequestInfo | URL, init?: RequestInit) =>
    window.fetch(input, init);

  // Fix "invalid DPoP proof header" — dpopKey.publicJwk is not a plain JSON object
  const storageKey = `@happyview/oauth(happyview:session:${session.did})`;
  const stored = localStorage.getItem(storageKey);
  if (stored) {
    const { dpopKey: rawJwk } = JSON.parse(stored);
    const { d: _, ...publicJwk } = rawJwk;
    Object.defineProperty((session as any).dpopKey, "publicJwk", {
      value: publicJwk,
      writable: true,
      configurable: true,
    });
  }
}

interface AuthState {
  session: HappyViewSession | null;
  loading: boolean;
  login: (handle: string) => Promise<void>;
  logout: () => void;
}

const AuthContext = createContext<AuthState>({
  session: null,
  loading: true,
  login: async () => {},
  logout: () => {},
});

export function useAuth() {
  return useContext(AuthContext);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<HappyViewSession | null>(null);
  const [loading, setLoading] = useState(true);

  const client = useMemo(() => {
    if (typeof window === "undefined") return null;
    const happyviewUrl = process.env.NEXT_PUBLIC_HAPPYVIEW_URL || window.location.origin;
    const isLoopback = window.location.hostname === "localhost";
    const clientId = isLoopback
      ? "http://localhost?scope=atproto"
      : `${window.location.origin}/oauth-client-metadata.json`;
    return new HappyViewBrowserClient({
      instanceUrl: happyviewUrl,
      clientId,
      clientKey: process.env.NEXT_PUBLIC_CLIENT_KEY!,
      redirectUri: `${window.location.origin}/auth/callback`,
      fetch: ((input: RequestInfo | URL, init?: RequestInit) => window.fetch(input, init)) as typeof fetch,
    });
  }, []);

  useEffect(() => {
    if (!client) return;
    client
      .restore()
      .then((restored) => {
        if (restored) {
          patchSession(restored);
          setSession(restored);
        }
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [client]);

  const login = useCallback(
    async (handle: string) => {
      if (!client) return;
      await client.login(handle);
    },
    [client],
  );

  const logout = useCallback(() => {
    if (!client || !session) return;
    client.logout(session.did);
    setSession(null);
  }, [client, session]);

  const value = useMemo(
    () => ({ session, loading, login, logout }),
    [session, loading, login, logout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
