// dsh-emacs-bridge — client (browser) bundle. The shared preset in
// deepseek-harness/packages/client/tsdown.client.ts (clientConfig) is
// repo-locked and cannot run for an out-of-tree package, so this replicates its
// artifact contract for this package alone. Keep the banner/footer/intro
// wrapper, the externals, the purity gate, and the define substitutions in sync
// with that preset (the contract is pre-release and the most likely thing to
// drift on a dsh version bump). Two preset pieces are deliberately not
// replicated: the CSS virtual-module plugins (this package has no stylesheets)
// and the tsc-sourcemap chaining/browserSourcePath (this build consumes src/
// directly, not the harness's lib/types layout).
import { readFileSync } from 'node:fs'
import type { UserConfig } from 'tsdown'

const id = 'dsh-emacs-bridge'

/** Baseline module-table rows, mirrored from packages/client/web/src/platform.ts. */
const PLATFORM_MODULES = [
  'react',
  'react/jsx-runtime',
  'react-dom',
  'react-dom/client',
  '@deepseek-ai/cordis',
  '@deepseek-ai/dsh-client-store',
  '@deepseek-ai/dsh-client-ui-slots',
  '@deepseek-ai/dsh-client-ui-primitives',
  '@deepseek-ai/dsh-client-ui-dockkit',
] as const

/** Dynamic rows the parser preloads before shell boot, from the same file. */
const PRELOADED_CLIENT_EXTERNALS = [] as const

/** The package's own non-baseline module-table requests (`dsh.client.external`). */
function requestedExternal(): ReadonlySet<string> {
  const manifest = JSON.parse(
    readFileSync(new URL('package.json', import.meta.url), 'utf8'),
  ) as { dsh?: { client?: { external?: unknown } } }
  const raw = manifest.dsh?.client?.external
  return new Set(Array.isArray(raw) ? raw.filter((entry): entry is string => typeof entry === 'string') : [])
}

const requested = requestedExternal()

/** Whether an import specifier is answered by the loader module table. */
function isExternal(specifier: string): boolean {
  return (PLATFORM_MODULES as readonly string[]).includes(specifier)
    || (PRELOADED_CLIENT_EXTERNALS as readonly string[]).includes(specifier)
    || requested.has(specifier)
}

/** Inline-safe wire layers and vendored libraries a client bundle may carry privately. */
const INLINE_SAFE =
  /^(?:@deepseek-ai\/dsh-(?:file-reference|session|llm|tools|brand|deque|output-retention|typert-protocol|util-crypto|util-values|util-workspace-path)(?:\/|$)|@deepseek-ai\/dsh-token-meter\/client$|@deepseek-ai\/dsh-host-open-in-app\/shared$|@deepseek-ai\/dsh-agent-presets\/display$|@deepseek-ai\/dsh-spill-policy\/notice$)/
const VENDORED_LIBRARY = /^@deepseek-ai\/(cosmokit|schemastery)(\/|$)/
const GENERATED_REMOTE = /^@deepseek-ai\/dsh-[a-z0-9]+(?:-[a-z0-9]+)*\/remote$/

/**
 * Build a node-idiom substitution set matching the shared preset's define:
 * the NODE_ENV/MODE triple plus `process.env` and the sorted passthrough of
 * public `DSH_CLIENT_*` build variables (clientBuildEnvironmentDefines,
 * without the repo-locked git/version resolution).
 */
function buildDefines(): Record<string, string> {
  const mode = JSON.stringify(process.env.NODE_ENV ?? 'production')
  const defines: Record<string, string> = {
    'process.env': '{}',
    'process.env.NODE_ENV': mode,
    'import.meta.env.MODE': mode,
    'import.meta.env': JSON.stringify({ MODE: process.env.NODE_ENV ?? 'production' }),
  }
  for (const name of Object.keys(process.env).filter(k => k.startsWith('DSH_CLIENT_')).sort()) {
    defines[`process.env.${name}`] = JSON.stringify(process.env[name])
  }
  return defines
}

const config: UserConfig = {
  name: `${id}/client`,
  entry: { client: 'src/client/index.ts' },
  outDir: 'lib',
  format: ['cjs'],
  platform: 'browser',
  target: 'es2024',
  dts: false,
  sourcemap: true,
  clean: false,
  deps: {
    // Requested module-table rows stay imports; everything else bundles. A
    // require() the table cannot answer throws at runtime.
    neverBundle: isExternal,
    alwaysBundle: (specifier: string) => !isExternal(specifier),
  },
  // Dual-mode libraries resolve their static flavor matching the NODE_ENV the
  // defines bake in (a CJS bundle cannot carry a top-level await).
  inputOptions: {
    resolve: {
      conditionNames: [
        (process.env.NODE_ENV ?? 'production') === 'development' ? 'development' : 'production',
        'browser', 'import', 'module', 'default',
      ],
    },
  },
  define: buildDefines(),
  plugins: [{
    // Bundle purity gate (mirror of tsdown.client.ts' dsh-client-bundle-purity):
    // a cross-plugin value import that is neither a requested module row nor an
    // inline-safe wire layer is a build error. Type-only imports are erased
    // before this runs, so they never reach the gate.
    name: 'dsh-client-bundle-purity',
    resolveId(source: string) {
      if (!source.startsWith('@deepseek-ai/')) return null
      if (isExternal(source)) return null
      if (INLINE_SAFE.test(source) || VENDORED_LIBRARY.test(source) || GENERATED_REMOTE.test(source)) return null
      throw new Error(
        `client bundle purity: "${source}" is not a requested module row, an inline-safe wire layer, `
        + 'or a generated /remote contribution — declare it in dsh.client.external or collaborate through cordis services',
      )
    },
  }],
  outputOptions: {
    entryFileNames: 'client.js',
    banner: `window.__ModuleLoader__.load({ id: ${JSON.stringify(id)}, factory: (require) => {`,
    footer: 'return module.exports; } });',
    intro: 'var module = { exports: {} }; var exports = module.exports;',
  },
}

export default config
