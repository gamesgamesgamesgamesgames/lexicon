import type { ReactNode } from "react";
import { RootProvider } from "fumadocs-ui/provider";
import { geistSans, geistMono } from "@lexicon/design-system/fonts";
import "./global.css";

export const metadata = {
  title: "The Pentaract",
  description: "The AppView for the games.gamesgamesgamesgames.* ATProto lexicons",
  icons: { icon: "/pentaract-logo.png" },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} dark`} suppressHydrationWarning>
      <body>
        <RootProvider>{children}</RootProvider>
      </body>
    </html>
  );
}
