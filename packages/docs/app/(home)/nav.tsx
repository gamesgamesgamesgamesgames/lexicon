"use client";

import Image from "next/image";
import Link from "next/link";
import { useState } from "react";
import { Button } from "@lexicon/design-system";
import { useAuth } from "@/lib/auth";

const GITHUB_URL = "https://github.com/gamesgamesgamesgamesgames/lexicon";

export function Nav() {
  const { session, loading, login, logout } = useAuth();
  const [handle, setHandle] = useState("");
  const [showLogin, setShowLogin] = useState(false);
  const [signingIn, setSigningIn] = useState(false);

  return (
    <header className="sticky top-0 z-40 border-b border-border/60 bg-bg/80 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6">
        <Link href="/" className="flex items-center gap-2 font-mono text-sm tracking-tight text-fg">
          <Image src="/pentaract-logo.png" alt="" width={24} height={24} className="h-6 w-6" />
          The Pentaract
        </Link>
        <nav className="flex items-center gap-1">
          <Link
            href="/docs"
            className="inline-flex h-8 items-center rounded-md px-3 text-xs text-fg-muted hover:text-fg"
          >
            Docs
          </Link>
          <a
            href={GITHUB_URL}
            className="inline-flex h-8 items-center rounded-md px-3 text-xs text-fg-muted hover:text-fg"
          >
            GitHub
          </a>
          {loading ? null : session ? (
            <>
              <Link
                href="/dashboard"
                className="inline-flex h-8 items-center rounded-md px-3 text-xs text-fg-muted hover:text-fg"
              >
                Dashboard
              </Link>
              <button
                onClick={logout}
                className="ml-2 inline-flex h-8 items-center rounded-md px-3 text-xs text-fg-muted hover:text-fg"
              >
                Sign out
              </button>
            </>
          ) : showLogin ? (
            <form
              className="ml-2 flex items-center gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                if (handle.trim()) {
                  setSigningIn(true);
                  login(handle.trim());
                }
              }}
            >
              <input
                type="text"
                placeholder="your.handle"
                value={handle}
                onChange={(e) => setHandle(e.target.value)}
                disabled={signingIn}
                className="h-8 rounded-md border border-border bg-bg px-3 font-mono text-sm text-fg placeholder:text-fg-subtle focus:border-accent focus:outline-none disabled:opacity-50"
                autoFocus
              />
              <Button size="sm" type="submit" disabled={signingIn}>
                {signingIn ? "Signing in…" : "Go"}
              </Button>
              <button
                type="button"
                onClick={() => setShowLogin(false)}
                disabled={signingIn}
                className="h-8 px-2 text-xs text-fg-muted hover:text-fg disabled:opacity-50"
              >
                ✕
              </button>
            </form>
          ) : (
            <Button size="sm" variant="secondary" onClick={() => setShowLogin(true)} className="ml-2">
              Sign in
            </Button>
          )}
        </nav>
      </div>
    </header>
  );
}
