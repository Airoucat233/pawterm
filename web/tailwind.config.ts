import type { Config } from 'tailwindcss';

export default {
  content: ['./index.html', './admin.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        bg: { DEFAULT: '#0B1210', light: '#F8FAF9' },
        surface: { DEFAULT: '#141B18', light: '#FFFFFF' },
        surfaceHi: { DEFAULT: '#1A221E', light: '#F2F6F4' },
        border: { DEFAULT: '#2A332E', light: '#DDE5E1' },
        text: { DEFAULT: '#E6E6E6', light: '#1A1F1C' },
        muted: { DEFAULT: '#9BA39E', light: '#565F5A' },
        dim: { DEFAULT: '#6B746F', light: '#8E948F' },
        accent: { DEFAULT: '#10B981', light: '#059669' },
      },
      fontFamily: {
        mono: ['JetBrains Mono', 'SF Mono', 'monospace'],
      },
    },
  },
  plugins: [],
} satisfies Config;
