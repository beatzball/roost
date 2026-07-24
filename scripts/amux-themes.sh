# amux-themes.sh — theme name → six colour values.
# Order: bar-bg bar-fg logo-bg active-bg active-fg idle-fg
# All values are contrast-validated by tests/test-contrast.py.
amux_theme_names() { printf '%s\n' amux catppuccin-mocha catppuccin-latte tokyonight-storm tokyonight-day gruvbox nord rose-pine; }
amux_theme() {
  case "$1" in
    amux)             echo "#211e38 #c8c3e0 #7c6ff0 #bd93f9 #12101f #8a84b0" ;;
    catppuccin-mocha) echo "#1e1e2e #cdd6f4 #89b4fa #cba6f7 #1e1e2e #9399b2" ;;
    catppuccin-latte) echo "#eff1f5 #4c4f69 #1e66f5 #8839ef #eff1f5 #5c5f77" ;;
    tokyonight-storm) echo "#24283b #c0caf5 #7aa2f7 #bb9af7 #1f2335 #9aa5ce" ;;
    tokyonight-day)   echo "#e1e2e7 #343b58 #2e7de9 #7847bd #e1e2e7 #565f89" ;;
    gruvbox)          echo "#282828 #ebdbb2 #fe8019 #b8bb26 #1d2021 #a89984" ;;
    nord)             echo "#2e3440 #eceff4 #88c0d0 #b48ead #242830 #a7b0c0" ;;
    rose-pine)        echo "#191724 #e0def4 #9ccfd8 #ebbcba #191724 #908caa" ;;
    *) return 1 ;;
  esac
}
