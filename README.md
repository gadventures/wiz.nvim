# wiz.nvim

Wiz security scanning for Neovim / LazyVim. `wizcli` runs the scan; the Wiz GraphQL API supplies the structured results.

- **Scan types:** IaC misconfigurations, hardcoded secrets, vulnerable dependencies (SCA), container base images
- **Triggers:** on demand (`:Wiz scan ...`), on project open, on save (opt-in), git pre-commit hook helper
- **UI:** native `vim.diagnostic` (works with `]d` / `[d` and Trouble), findings picker (Snacks / fzf-lua / Telescope), details float
- **Extras:** severity threshold, ignore findings, lualine statusline counts, open in the Wiz portal

> **Status:** design approved (rev 2), implementation not started.
> - [Design spec](docs/specs/2026-11-27-wiz-nvim-design.md)
> - [Implementation plan](docs/plans/2026-11-27-wiz-nvim-implementation.md)

## Requirements (planned)

- Neovim >= 0.10, `curl`
- `wizcli` v1.x on `PATH`
- A Wiz service account, exposed through environment variables:

| Variable | Required | Example / default |
|---|---|---|
| `WIZ_CLIENT_ID` | yes | |
| `WIZ_CLIENT_SECRET` | yes | |
| `WIZ_API_ENDPOINT` | yes | `https://api.us17.app.wiz.io/graphql` |
| `WIZ_AUTH_URL` | no | `https://auth.app.wiz.io/oauth/token` |
| `WIZ_AUTH_AUDIENCE` | no | `wiz-api` |

Load the secrets from a secret manager in your shell profile; don't put them in your Neovim config.

- Docker (only for container image scans)

## Installation (planned)

```lua
-- ~/.config/nvim/lua/plugins/wiz.lua
return {
  "gadventures/wiz.nvim",
  url = "git@github.com:gadventures/wiz.nvim.git", -- private repo
  cmd = "Wiz",
  event = { "BufReadPost", "BufWritePost" },
  opts = { min_severity = "MEDIUM" },
}
```

Then run `:checkhealth wiz`.
