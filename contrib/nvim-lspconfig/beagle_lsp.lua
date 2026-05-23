-- nvim-lspconfig configuration for beagle-lsp
--
-- This file is intended for upstream submission to neovim/nvim-lspconfig
-- under `lua/lspconfig/configs/beagle_lsp.lua`. Until merged, drop it
-- into your local nvim config:
--
--   :lua require'lspconfig.configs'.beagle_lsp = require'beagle_lsp'
--   :lua require'lspconfig'.beagle_lsp.setup{}
--
-- Then optionally register file types so :LspInfo recognizes them:
--
--   vim.filetype.add({
--     extension = {
--       bnix  = 'beagle', bclj  = 'beagle', bcljs = 'beagle',
--       bjs   = 'beagle', bpy   = 'beagle', bsql  = 'beagle',
--       bgl   = 'beagle',
--     },
--   })

local util = require('lspconfig.util')

return {
  default_config = {
    cmd = { 'beagle-lsp' },
    filetypes = {
      'beagle',
      -- Direct extension fallbacks for users who haven't added the
      -- ftdetect rule above:
      'bnix',
      'bclj',
      'bcljs',
      'bjs',
      'bpy',
      'bsql',
      'bgl',
    },
    root_dir = function(fname)
      return util.root_pattern('.beagle-cache', 'flake.bnix', 'flake.nix', '.git')(fname)
        or util.path.dirname(fname)
    end,
    single_file_support = true,
    settings = {},
  },
  docs = {
    description = [[
beagle-lsp — language server for the beagle authoring language family.

beagle is a typed s-expression language that compiles to Nix, Clojure,
JavaScript, Python, ClojureScript, SQL, or Typed Racket. The LSP provides
hover types (target-aware against the appropriate stdlib catalog), diagnostics,
completion, and go-to-definition. For #lang beagle/nix files it also resolves
config.X.Y references against a NixOS option schema cached in .beagle-cache/.

Install beagle: https://github.com/tompassarelli/beagle
]],
    default_config = {
      root_dir = [[root_pattern('.beagle-cache', 'flake.bnix', 'flake.nix', '.git')]],
    },
  },
}
