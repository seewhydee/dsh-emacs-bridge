// dsh-emacs-bridge — integration spec: the route fences (bearer auth, SSE
// token, loopback/origin token-vend).
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
// Pins the fence contract the README's "Permissions, authentication, and
// failure bounds" section documents: every /dsh-bridge route requires the
// shared bearer token except /token and /status (fenced by loopback peer +
// origin instead) and /events (EventSource cannot set headers, so the token
// rides the query string). The peer-address arm of the /token//status fence
// is unforgeable from this client and always passes here; the origin arm is
// what these tests exercise.

import { describe, it, expect, inject } from 'vitest'
import { raw } from './util.mjs'

const HOSTILE_ORIGIN = 'https://evil.example'

describe('bearer-token fence', () => {
  it('rejects a missing or wrong bearer token on representative fenced routes', async () => {
    const fixture = inject('fixture')
    const cases = [
      ['GET', '/dsh-bridge/sessions', undefined],
      ['POST', '/dsh-bridge/send', { text: 'hi' }],
      ['GET', '/dsh-bridge/outbox', undefined],
    ]
    for (const [method, path, body] of cases) {
      const missing = await raw(fixture, method, path, { body })
      expect(missing.status, `${method} ${path} without a token`).toBe(401)
      expect(missing.body.error).toBe('unauthorized')

      const wrong = await raw(fixture, method, path, { token: 'wrong-token', body })
      expect(wrong.status, `${method} ${path} with a wrong token`).toBe(401)
      expect(wrong.body.error).toBe('unauthorized')
    }
  }, 30000)

  it('rejects a wrong query token on the SSE route (EventSource cannot set headers)', async () => {
    const fixture = inject('fixture')
    const wrong = await raw(fixture, 'GET', '/dsh-bridge/events?token=wrong-token')
    expect(wrong.status).toBe(401)
    expect(wrong.body.error).toBe('unauthorized')

    const missing = await raw(fixture, 'GET', '/dsh-bridge/events')
    expect(missing.status).toBe(401)
  }, 30000)
})

describe('loopback token-vend fence (/token and /status)', () => {
  it('vends the token to a loopback peer carrying no hostile origin', async () => {
    const fixture = inject('fixture')
    const vend = await raw(fixture, 'GET', '/dsh-bridge/token')
    expect(vend.status).toBe(200)
    expect(vend.body.token).toBe(fixture.token)
  }, 30000)

  it('answers /status without a bearer token', async () => {
    const fixture = inject('fixture')
    const status = await raw(fixture, 'GET', '/dsh-bridge/status')
    expect(status.status).toBe(200)
    expect(status.body.name).toBe('dsh-emacs-bridge')
  }, 30000)

  it('forbids a hostile Origin on both /token and /status', async () => {
    const fixture = inject('fixture')
    for (const path of ['/dsh-bridge/token', '/dsh-bridge/status']) {
      const hostile = await raw(fixture, 'GET', path, { origin: HOSTILE_ORIGIN })
      expect(hostile.status, `${path} with a hostile origin`).toBe(403)
      expect(hostile.body.error).toBe('forbidden')

      // The same route without the Origin header (the loopback peer arm is
      // unchanged) still succeeds.
      const plain = await raw(fixture, 'GET', path)
      expect(plain.status, `${path} without an origin`).toBe(200)
    }
  }, 30000)
})
