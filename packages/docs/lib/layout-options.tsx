import Image from "next/image";
import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";

export const baseOptions: BaseLayoutProps = {
  nav: {
    title: (
      <span className="flex items-center gap-2 text-sm tracking-tight">
        <Image
          src="/pentaract-logo.png"
          alt=""
          width={24}
          height={24}
          className="h-6 w-6"
        />
        <span className="font-[family-name:var(--font-dragonsteel)] text-lg">The Pentaract</span>
      </span>
    ),
  },
  links: [
    {
      text: "Docs",
      url: "/docs",
      active: "nested-url",
    },
    {
      text: "GitHub",
      url: "https://github.com/gamesgamesgamesgamesgames/lexicon",
      external: true,
    },
    {
      text: "Discord",
      url: "https://discord.gg/BUPnjaBwRZ",
      external: true,
    },
  ],
};
