// dsh-emacs-bridge — integration-testing mock Host-operation plugin.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// Plain-ESM Cordis plugin (no build step) exposing the one Host operation the
// web profile no longer reaches from a model turn: moving a Session's working
// directory.  DSH records such a move as `working-directory/change` (on the
// compatibility release) or `workspace-root/change` (master), but only Host
// operations perform it (SDK `setWorkingDirectory`, the worktree tools, the
// forge panel, directory recovery); none of those is mounted in the plain web
// profile.
// This fixture plays the Host: its loopback route calls the harness's own
// `ctx.workingDirectory.set(agent, path)`, so the committed event is the real
// one.
//
// The route is guarded by the same bearer token as the bridge routes, read
// lazily per request from `$DSH_HOME/dsh-bridge-token` (the bridge writes that
// file at its own boot, which may order after ours).  Nothing here is shipped:
// the module lives only in the developer-only integration harness.

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

export const name = 'dsh-bridge-mock-host'

export const inject = ['webServer']

/** Read the shared bridge token from $DSH_HOME/dsh-bridge-token, or null. */
function readToken() {
  const dshHome = process.env.DSH_HOME || join(homedir(), '.dsh')
  const path = join(dshHome, 'dsh-bridge-token')
  if (!existsSync(path)) return null
  const value = readFileSync(path, 'utf8').trim()
  return value === '' ? null : value
}

/** Constant-time-ish bearer comparison against the shared token. */
function bearerOk(req) {
  const header = req.headers.authorization
  if (typeof header !== 'string') return false
  const prefix = 'Bearer '
  if (!header.startsWith(prefix)) return false
  const provided = header.slice(prefix.length)
  const token = readToken()
  if (token === null || provided.length !== token.length) return false
  let diff = 0
  for (let i = 0; i < provided.length; i += 1) diff |= provided.charCodeAt(i) ^ token.charCodeAt(i)
  return diff === 0
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = ''
    req.setEncoding('utf8')
    req.on('data', (chunk) => { body += chunk })
    req.on('end', () => {
      try { resolve(body === '' ? undefined : JSON.parse(body)) } catch (error) { reject(error) }
    })
    req.on('error', reject)
  })
}

function sendJson(res, status, value) {
  const payload = JSON.stringify(value)
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(payload)
}

export function apply(ctx) {
  const webServer = ctx.get('webServer')

  // Registered inside an effect so hot-reload re-applies it without a
  // duplicate (kind, path) registration throw. `auth: 'anonymous'` keeps the
  // route reachable with only the bridge token: a host with route admission
  // defaults to `required` and would deny a credential-free test client 401
  // before the bearer check below runs.
  ctx.effect(() => webServer.register({
    kind: 'prefix',
    path: '/mock-host',
    auth: 'anonymous',
    handler: async (req, res) => {
      const url = new URL(req.url ?? '/', 'http://localhost')
      if (!bearerOk(req)) {
        sendJson(res, 401, { error: 'unauthorized' })
        return
      }
      if (req.method === 'POST' && url.pathname === '/mock-host/working-directory') {
        const body = (await readJson(req)) ?? {}
        if (typeof body.sessionId !== 'string' || body.sessionId === ''
          || typeof body.path !== 'string' || body.path === '') {
          sendJson(res, 400, { error: 'sessionId and path must be non-empty strings' })
          return
        }
        const agents = ctx.get('agents')
        const workingDirectory = ctx.get('workingDirectory')
        if (agents === undefined || workingDirectory === undefined) {
          // A harness generation without these services cannot exercise the
          // seam; answer distinctly so the spec's failure names the cause.
          sendJson(res, 501, { error: 'agents or workingDirectory unavailable' })
          return
        }
        const agent = agents.get(body.sessionId)
        if (agent === undefined) {
          sendJson(res, 404, { error: 'session is not live' })
          return
        }
        try {
          const cwd = await workingDirectory.set(agent, body.path)
          sendJson(res, 200, { cwd })
        } catch (error) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }
      sendJson(res, 404, { error: 'not found' })
    },
  }))
}
