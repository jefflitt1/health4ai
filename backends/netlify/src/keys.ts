// Device keys and the setup secret.
//
// A Device key is 24 random bytes, base64url, behind a fixed prefix so a leaked one is
// recognisable in logs and paste buffers. Only its SHA-256 hash is stored, so a database read
// never yields a usable key. SHA-256 without a salt is enough here because the key is random, not
// a human-chosen password: there is no dictionary to precompute.

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'

const KEY_PREFIX = 'h4a_'
const DISPLAY_PREFIX_LENGTH = 11

export interface NewDeviceKey {
  plaintext: string
  hash: string
  displayPrefix: string
}

export function generateDeviceKey(): NewDeviceKey {
  const plaintext = KEY_PREFIX + randomBytes(24).toString('base64url')
  return { plaintext, hash: hashDeviceKey(plaintext), displayPrefix: plaintext.slice(0, DISPLAY_PREFIX_LENGTH) }
}

export function hashDeviceKey(plaintext: string): string {
  return createHash('sha256').update(plaintext, 'utf8').digest('hex')
}

/**
 * Compares a presented setup secret with the configured one in constant time. Both sides are
 * hashed first so the comparison does not leak the configured secret's length. An unset or empty
 * configured secret matches nothing: a Deployment nobody configured must not be open to everyone.
 */
export function setupSecretMatches(presented: string | null, configured: string | undefined): boolean {
  if (!configured || !presented) return false
  const a = createHash('sha256').update(presented, 'utf8').digest()
  const b = createHash('sha256').update(configured, 'utf8').digest()
  return timingSafeEqual(a, b)
}
