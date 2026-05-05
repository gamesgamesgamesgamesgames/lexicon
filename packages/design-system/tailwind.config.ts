import type { Config } from "tailwindcss";

const rgba = (token: string) => `rgb(var(${token}) / <alpha-value>)`;

const preset: Partial<Config> = {
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        bg: {
          DEFAULT: rgba("--color-bg"),
          subtle: rgba("--color-bg-subtle"),
        },
        surface: rgba("--color-surface"),
        border: {
          DEFAULT: rgba("--color-border"),
          strong: rgba("--color-border-strong"),
        },
        fg: {
          DEFAULT: rgba("--color-fg"),
          muted: rgba("--color-fg-muted"),
          subtle: rgba("--color-fg-subtle"),
        },
        accent: {
          DEFAULT: rgba("--color-accent"),
          fg: rgba("--color-accent-fg"),
          subtle: rgba("--color-accent-subtle"),
        },
        code: {
          bg: rgba("--color-code-bg"),
          fg: rgba("--color-code-fg"),
        },
      },
      fontFamily: {
        sans: ["var(--font-sans)"],
        mono: ["var(--font-mono)"],
      },
      borderRadius: {
        sm: "var(--radius-sm)",
        md: "var(--radius-md)",
        lg: "var(--radius-lg)",
      },
    },
  },
  plugins: [],
};

export default preset;
