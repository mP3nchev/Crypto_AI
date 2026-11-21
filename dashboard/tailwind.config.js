// Design tokens taken 1:1 from the provided design
// (automated_crypto_signal_virtual_portfolio_dashboard.html).
// Change colours here to re-skin the whole dashboard.
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'sans-serif'],
        mono: ['JetBrains Mono', 'monospace'],
      },
      colors: {
        obsidian: '#0B0E14',
        surface: '#151A23',
        surfaceHover: '#1B222E',
        borderSubtle: '#232A3B',
        emeraldNeon: '#00E676',
        crimsonNeon: '#FF3B69',
        electricBlue: '#2979FF',
        amberWarn: '#FFB300',
      },
    },
  },
  plugins: [],
};
