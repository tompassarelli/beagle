# nvim-lspconfig + beagle lsp

Until [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) merges
beagle support upstream, drop this stanza into your Neovim config.

## Setup

### 1. Install beagle (provides `beagle lsp`)

See main repo README. After install, `beagle lsp` is on your PATH.

### 2. Register the language server

Drop `beagle_lsp.lua` into your nvim config (e.g. `~/.config/nvim/lua/`),
then in your init:

```lua
-- Register file types so nvim auto-attaches the LSP.
vim.filetype.add({
  extension = {
    bnix  = 'beagle',
    bclj  = 'beagle',
    bcljs = 'beagle',
    bjs   = 'beagle',
    bpy   = 'beagle',
    bsql  = 'beagle',
    bgl   = 'beagle',
  },
})

-- Register the LSP config.
require('lspconfig.configs').beagle_lsp = require('beagle_lsp')
require('lspconfig').beagle_lsp.setup({})
```

### 3. Pair with [tree-sitter-beagle](https://github.com/tompassarelli/tree-sitter-beagle)

For syntax highlighting alongside the LSP, install the tree-sitter grammar:

```lua
local parser_config = require'nvim-treesitter.parsers'.get_parser_configs()
parser_config.beagle = {
  install_info = {
    url = 'https://github.com/tompassarelli/tree-sitter-beagle',
    files = { 'src/parser.c' },
  },
  filetype = 'beagle',
}
```

Then `:TSInstall beagle`.

## What you get

- **Hover** — type signatures for stdlib functions (target-aware: clj catalog in `.bclj`, nix in `.bnix`)
- **Diagnostics** — type errors, schema mismatches, "did you mean?" suggestions
- **Completion** — stdlib functions filtered by current target
- **Go to definition** — cross-module navigation
- **Symbols** — outline view of defs/defns/records

For `#lang beagle/nix` files, the LSP additionally:
- Looks up `config.X.Y` paths in the loaded NixOS schema and shows the type
- Catches typos in option paths
- Flow-narrows nullable schema fields inside `if`/`when` branches

## Upstream PR status

Tracking issue: TODO (open one in nvim-lspconfig once beagle has v0.14+).

The stanza format here matches the new `lua/lspconfig/configs/<name>.lua`
shape used by recent nvim-lspconfig versions. Earlier nvim-lspconfig versions
used a single `lua/lspconfig/server_configurations/<name>.lua` — adapt
accordingly.
