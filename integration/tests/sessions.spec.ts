// dsh-emacs-bridge — integration spec: session creation and workspace lifecycle.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Drives the host-side management surface over real HTTP against the shared
// live fixture: create-by-path (new and already-known workspace), create-by-
// workspaceId, workspace rename with its conflict/validation bounds, session
// rename and archive, and the create-argument failure semantics. Each test
// works in its own OS temp directory so the shared, durable workspace registry
// stays deterministic across specs.

import { afterAll, describe, expect, it, inject } from 'vitest'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { get, post } from './util.mjs'

/** Temp workspace directories created by this spec, removed on teardown. */
const tempDirs = []

/** A fresh, canonical, fully-qualified temp directory for one workspace. */
function tempWorkspace() {
  // realpath matters: the registry canonicalizes with fs.realpath, and the
  // bridge echoes that canonical path back as `cwd`/`path`.
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dsh-bridge-ws-')))
  tempDirs.push(dir)
  return dir
}

let seq = 0
/** A title unique to this run, so rename-conflict assertions stay exact. */
function uniqueTitle(prefix) {
  seq += 1
  return `${prefix} ${process.pid}-${Date.now()}-${seq}`
}

function sessionRows(body) {
  return body.sessions ?? []
}

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true })
})

describe('session creation in a workspace', () => {
  it('creates a session in a new workspace and exposes it on both rosters', async () => {
    const fixture = inject('fixture')
    const dir = tempWorkspace()
    const title = uniqueTitle('new-workspace')

    const created = await post(fixture, '/dsh-bridge/sessions/create', {
      path: dir,
      workspaceTitle: title,
    })
    expect(created.status).toBe(201)
    expect(created.body.ok).toBe(true)
    expect(typeof created.body.sessionId).toBe('string')
    expect(typeof created.body.workspaceId).toBe('string')
    // The workspace path is canonicalized (realpath) before it is stored.
    expect(created.body.cwd).toBe(dir)

    const workspaces = await get(fixture, '/dsh-bridge/workspaces')
    expect(workspaces.status).toBe(200)
    const workspace = workspaces.body.workspaces.find((w) => w.id === created.body.workspaceId)
    expect(workspace).toBeDefined()
    expect(workspace.path).toBe(dir)
    expect(workspace.title).toBe(title)

    const sessions = await get(fixture, '/dsh-bridge/sessions')
    expect(sessions.status).toBe(200)
    const row = sessionRows(sessions.body).find((s) => s.id === created.body.sessionId)
    expect(row).toBeDefined()
    expect(row.live).toBe(true)
    expect(row.cwd).toBe(dir)
    expect(row.workspaceId).toBe(created.body.workspaceId)
    expect(row.workspace).toBe(title)
    expect(row.archived).toBe(false)
  }, 60000)

  it('resolves an existing workspace when the same path is created again', async () => {
    const fixture = inject('fixture')
    const dir = tempWorkspace()
    const title = uniqueTitle('resolve-path')

    const first = await post(fixture, '/dsh-bridge/sessions/create', {
      path: dir,
      workspaceTitle: title,
    })
    expect(first.status).toBe(201)

    // No title: resolveByPath must adopt the existing workspace, not create a
    // second record for the same canonical path.
    const second = await post(fixture, '/dsh-bridge/sessions/create', { path: dir })
    expect(second.status).toBe(201)
    expect(second.body.workspaceId).toBe(first.body.workspaceId)
    expect(second.body.sessionId).not.toBe(first.body.sessionId)

    const workspaces = await get(fixture, '/dsh-bridge/workspaces')
    const matches = workspaces.body.workspaces.filter((w) => w.path === dir)
    expect(matches).toHaveLength(1)
    expect(matches[0].id).toBe(first.body.workspaceId)
    expect(matches[0].title).toBe(title)
  }, 60000)

  it('attaches a second session to an existing workspace by workspaceId', async () => {
    const fixture = inject('fixture')
    const dir = tempWorkspace()

    const first = await post(fixture, '/dsh-bridge/sessions/create', {
      path: dir,
      workspaceTitle: uniqueTitle('by-id'),
    })
    expect(first.status).toBe(201)

    const second = await post(fixture, '/dsh-bridge/sessions/create', {
      workspaceId: first.body.workspaceId,
    })
    expect(second.status).toBe(201)
    expect(second.body.workspaceId).toBe(first.body.workspaceId)
    expect(second.body.cwd).toBe(dir)
    expect(second.body.sessionId).not.toBe(first.body.sessionId)

    const sessions = await get(fixture, '/dsh-bridge/sessions')
    const attached = sessionRows(sessions.body)
      .filter((s) => s.workspaceId === first.body.workspaceId)
      .map((s) => s.id)
    expect(attached).toEqual(expect.arrayContaining([first.body.sessionId, second.body.sessionId]))
  }, 60000)

  it('rejects create arguments that name zero or two workspaces', async () => {
    const fixture = inject('fixture')
    const dir = tempWorkspace()

    const neither = await post(fixture, '/dsh-bridge/sessions/create', {})
    expect(neither.status).toBe(400)

    const both = await post(fixture, '/dsh-bridge/sessions/create', {
      workspaceId: 'ws-ignored',
      path: dir,
    })
    expect(both.status).toBe(400)

    const unknown = await post(fixture, '/dsh-bridge/sessions/create', {
      workspaceId: 'ws-does-not-exist',
    })
    expect(unknown.status).toBe(404)
  }, 60000)

  it('rejects a workspace path that is not an existing directory', async () => {
    const fixture = inject('fixture')
    const missing = join(tmpdir(), `dsh-bridge-missing-${Date.now()}`)

    const created = await post(fixture, '/dsh-bridge/sessions/create', { path: missing })
    // The registry's realpath rejects with ENOENT, which the bridge surfaces as
    // an error (not 201). This is the host contract the Emacs package's
    // expand-and-check prompt flow exists to satisfy.
    expect(created.status).toBeGreaterThanOrEqual(400)
    expect(created.body.sessionId).toBeUndefined()
  }, 60000)
})

describe('workspace management', () => {
  it('renames a workspace, and bounds conflict, blank, and unknown input', async () => {
    const fixture = inject('fixture')
    const dirA = tempWorkspace()
    const dirB = tempWorkspace()
    const titleA = uniqueTitle('rename-a')
    const titleB = uniqueTitle('rename-b')

    const a = await post(fixture, '/dsh-bridge/sessions/create', {
      path: dirA,
      workspaceTitle: titleA,
    })
    const b = await post(fixture, '/dsh-bridge/sessions/create', {
      path: dirB,
      workspaceTitle: titleB,
    })
    expect(a.status).toBe(201)
    expect(b.status).toBe(201)

    const renamed = await post(fixture, '/dsh-bridge/workspaces/rename', {
      workspaceId: a.body.workspaceId,
      title: `${titleA} renamed`,
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body.ok).toBe(true)
    expect(renamed.body.title).toBe(`${titleA} renamed`)

    const roster = await get(fixture, '/dsh-bridge/workspaces')
    const workspace = roster.body.workspaces.find((w) => w.id === a.body.workspaceId)
    expect(workspace.title).toBe(`${titleA} renamed`)

    // A title already held by another workspace is a conflict.
    const conflict = await post(fixture, '/dsh-bridge/workspaces/rename', {
      workspaceId: a.body.workspaceId,
      title: titleB,
    })
    expect(conflict.status).toBe(409)

    const blank = await post(fixture, '/dsh-bridge/workspaces/rename', {
      workspaceId: a.body.workspaceId,
      title: '   ',
    })
    expect(blank.status).toBe(400)

    const unknown = await post(fixture, '/dsh-bridge/workspaces/rename', {
      workspaceId: 'ws-does-not-exist',
      title: uniqueTitle('unknown'),
    })
    expect(unknown.status).toBe(404)
  }, 60000)
})

describe('session management', () => {
  it('renames and archives a session, and reports unknown ids', async () => {
    const fixture = inject('fixture')
    const dir = tempWorkspace()
    const title = uniqueTitle('session-ops')

    const created = await post(fixture, '/dsh-bridge/sessions/create', {
      path: dir,
      workspaceTitle: title,
    })
    expect(created.status).toBe(201)
    const id = created.body.sessionId

    const renamed = await post(fixture, '/dsh-bridge/sessions/rename', {
      sessionId: id,
      title: 'Renamed by the bridge spec',
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body.title).toBe('Renamed by the bridge spec')

    const rows = sessionRows((await get(fixture, '/dsh-bridge/sessions')).body)
    expect(rows.find((s) => s.id === id).title).toBe('Renamed by the bridge spec')

    const missing = await post(fixture, '/dsh-bridge/sessions/rename', { sessionId: id })
    expect(missing.status).toBe(400)

    const archived = await post(fixture, '/dsh-bridge/sessions/archive', { sessionId: id })
    expect(archived.status).toBe(200)
    expect(archived.body.ok).toBe(true)

    // Archived sessions stay listed (the surface marks them); Emacs hides them.
    const after = sessionRows((await get(fixture, '/dsh-bridge/sessions')).body)
    expect(after.find((s) => s.id === id).archived).toBe(true)

    const unknown = await post(fixture, '/dsh-bridge/sessions/archive', {
      sessionId: 'session-does-not-exist',
    })
    expect(unknown.status).toBe(404)
  }, 60000)
})
