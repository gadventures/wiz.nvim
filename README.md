# wiz.nvim

Wiz security scanning for Neovim / LazyVim, powered by [`wizcli`](https://www.wiz.io/lp/wiz-cli).

Brings the Wiz IDE experience (as in the Wiz VS Code and JetBrains extensions) to Neovim:

- **Scan types:** IaC misconfigurations, hardcoded secrets, vulnerable dependencies (SCA), container base images
- **Triggers:** on save, on demand (`:Wiz scan ...`), on project open, git pre-commit hook helper
- **UI:** native `vim.diagnostic` (works with `]d` / `[d` and Trouble), findings picker (Snacks / fzf-lua / Telescope), details float
- **Extras:** severity threshold, ignore findings, lualine statusline counts, open finding in the Wiz portal

> **Status:** design approved, implementation not started. See the [design spec](docs/specs/2026-11-27-wiz-nvim-design.md).

## Requirements (planned)

- Neovim >= 0.10
- `wizcli` on `PATH`, authenticated with `wizcli auth`
- Docker (only for container image scans)

## Installation (planned)

```lua
-- lazy.nvim / LazyVim
{
  "gadventures/wiz.nvim",
  cmd = "Wiz",
  event = { "BufReadPost", "BufWritePost" },
  opts = { min_severity = "MEDIUM" },
}
```

Then run `:checkhealth wiz`.
