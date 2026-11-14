// dsh-emacs-bridge — bounded retry-list maintenance for browser dismissals.
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

export interface DismissRecordTiming {
  readonly at?: number
}

/** Drop records older than TTL milliseconds; timeless records remain pending. */
export function expireDismissRecords<T extends DismissRecordTiming>(
  records: T[],
  now: number,
  ttlMs: number,
): void {
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const at = records[index]?.at
    if (at !== undefined && now - at > ttlMs) records.splice(index, 1)
  }
}

/** Append one retry record, evicting the oldest beyond CAP. */
export function appendDismissRecord<T>(records: T[], record: T, cap: number): void {
  records.push(record)
  if (records.length > cap) records.shift()
}
