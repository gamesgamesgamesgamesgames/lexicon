import type { Config } from "tailwindcss";
import preset from "@lexicon/design-system/tailwind.config";

const config: Config = {
  presets: [preset as Config],
  content: [
    "./app/**/*.{ts,tsx,mdx}",
    "./content/**/*.{md,mdx}",
    "../../packages/design-system/src/**/*.{ts,tsx}",
    "./node_modules/fumadocs-ui/dist/**/*.js",
  ],
};

export default config;
