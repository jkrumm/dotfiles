// kuma-door registry — the single list of services the door exposes, and the one place it is
// validated. door.ts (runtime) and gen.ts (Kuma monitor generator) both import this module, so a
// registry the door would refuse can never be generated into Kuma.
import { readFileSync } from "node:fs"
import { join } from "node:path"

export type Service = { name: string; url: string; title: string; interval?: number }
export type Registry = { port: number; services: Service[] }

export const REGISTRY_PATH = join(import.meta.dir, "registry.json")

const NAME_RE = /^[a-z0-9][a-z0-9-]*$/
const LOOPBACK_PREFIX = "http://127.0.0.1:"
const MIN_INTERVAL = 20 // Uptime Kuma's floor

const isPort = (n: unknown): n is number => Number.isInteger(n) && (n as number) >= 1 && (n as number) <= 65535

// Collects every problem so one run names all of them; throws once at the end.
export function validateRegistry(raw: unknown): Registry {
  const errors: string[] = []
  const root = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>

  if (!isPort(root.port)) errors.push("port: missing or not an integer 1-65535")
  if (!Array.isArray(root.services) || root.services.length === 0) errors.push("services: missing or empty")

  const seen = new Set<string>()
  const services = Array.isArray(root.services) ? root.services : []
  services.forEach((entry, i) => {
    const s = (entry && typeof entry === "object" ? entry : {}) as Record<string, unknown>
    const at = typeof s.name === "string" ? `services[${i}] (${s.name})` : `services[${i}]`
    if (typeof s.name !== "string" || !NAME_RE.test(s.name)) errors.push(`${at}: name must match ${NAME_RE}`)
    else if (seen.has(s.name)) errors.push(`${at}: duplicate name`)
    else seen.add(s.name)
    if (typeof s.title !== "string" || s.title.trim() === "") errors.push(`${at}: title must be a non-empty string`)
    if (!isLoopbackUrl(s.url)) errors.push(`${at}: url must be http://127.0.0.1:<port>/...`)
    if (s.interval !== undefined && !(Number.isInteger(s.interval) && (s.interval as number) >= MIN_INTERVAL)) {
      errors.push(`${at}: interval must be an integer >= ${MIN_INTERVAL}`)
    }
  })

  if (errors.length > 0) throw new Error(`invalid registry:\n  ${errors.join("\n  ")}`)
  return root as unknown as Registry
}

// The raw-prefix check rejects spellings URL() would normalise into loopback (127.1, 0x7f.1, ...).
function isLoopbackUrl(value: unknown): boolean {
  if (typeof value !== "string" || !value.startsWith(LOOPBACK_PREFIX)) return false
  try {
    const u = new URL(value)
    return u.protocol === "http:" && u.hostname === "127.0.0.1" && /^http:\/\/127\.0\.0\.1:\d+(?:[/?#]|$)/.test(value) && !u.username && !u.password
  } catch {
    return false
  }
}

export function loadRegistry(path: string = REGISTRY_PATH): Registry {
  return validateRegistry(JSON.parse(readFileSync(path, "utf8")))
}
