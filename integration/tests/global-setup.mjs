// dsh-emacs-bridge — integration-testing vitest globalSetup.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Boots the shared fixture once for the whole vitest project and tears it down
// afterwards. The fixture facts ({url, token}) are provided to each spec via
// `inject('fixture')`. The fixture's DSH_HOME lives in a per-run temp dir by
// default; a spec that needs to reuse a persisted home across two boots passes
// its own `dshHome` to the launcher and boots its own instance.

import { launch } from '../host/launch.mjs'

/** Boot the shared fixture; `teardown` kills it. */
export default async function setup({ provide }) {
  const fixture = await launch({ timeoutMs: 120000 })
  provide('fixture', {
    url: fixture.url,
    port: fixture.port,
    token: fixture.token,
    dshHome: fixture.dshHome,
    logPath: fixture.logPath,
    overlayPath: fixture.overlayPath,
    version: fixture.version,
  })
  return async () => {
    // Await so the dsh child is gone (and the launcher-owned temp home
    // removed) before the vitest process exits.
    await fixture.kill()
  }
}
