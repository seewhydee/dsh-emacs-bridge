// dsh-emacs-bridge — shared bearer-token machinery and authorized route
// calls for the browser half. The token is vended once by the loopback-fenced
// /dsh-bridge/token route, cached in memory and localStorage, and dropped on a
// 401 (the host regenerated the token file) for exactly one retry.
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

/** In-memory token cache, so the vend fetch happens at most once per page. */
let cachedToken: string | null = null

/** Forget the in-memory and stored token, forcing a fresh vend next time. */
function forgetToken(): void {
  cachedToken = null
  localStorage.removeItem('dsh-bridge-token')
}

/**
 * Resolve the bearer token: the in-memory cache, then `localStorage`, then the
 * loopback-fenced token-vend route (auto, with no manual paste).
 */
export async function getToken(): Promise<string> {
  if (cachedToken !== null) return cachedToken
  const stored = localStorage.getItem('dsh-bridge-token')
  if (stored !== null) {
    cachedToken = stored
    return stored
  }
  const response = await fetch('/dsh-bridge/token')
  if (!response.ok) throw new Error(`token fetch failed: HTTP ${response.status}`)
  const body = (await response.json()) as { token?: string }
  if (typeof body.token !== 'string' || body.token === '') {
    throw new Error('/dsh-bridge/token returned no token')
  }
  localStorage.setItem('dsh-bridge-token', body.token)
  cachedToken = body.token
  return body.token
}

/** One authorized POST to a bridge route; returns the response. */
export async function postAuthorized(path: string, payload: unknown, token: string): Promise<Response> {
  return fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(payload),
  })
}

/** One authorized GET to a bridge route; returns the response. */
export async function getAuthorized(path: string, token: string): Promise<Response> {
  return fetch(path, { headers: { Authorization: `Bearer ${token}` } })
}

/** One bridge call: a GET without a body, a POST with one. */
export type BridgeCall = { method: 'GET'; path: string } | { method: 'POST'; path: string; payload: unknown }

/** The response's JSON body, or undefined when it has none or is not JSON. */
async function readJsonBody(response: Response): Promise<unknown> {
  const text = await response.text()
  if (text === '') return undefined
  try {
    return JSON.parse(text) as unknown
  } catch {
    // A proxy error page or an empty response is not a bridge answer; the
    // caller's decision rests on `ok` and `status`, never on the parse.
    return undefined
  }
}

/**
 * Call one bridge route and read its JSON body. A 401 means the cached/stored
 * token is stale (the host regenerated the token file), so it is dropped and a
 * fresh one vended — exactly once; a second 401 is an error. A body that is
 * not JSON leaves `body` undefined rather than throwing.
 */
export async function callBridge(call: BridgeCall): Promise<{ ok: boolean; status: number; body: unknown }> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const token = await getToken()
    const response = call.method === 'GET'
      ? await getAuthorized(call.path, token)
      : await postAuthorized(call.path, call.payload, token)
    if (response.status === 401 && attempt === 0) {
      forgetToken()
      continue
    }
    return { ok: response.ok, status: response.status, body: await readJsonBody(response) }
  }
  throw new Error('HTTP 401')
}
