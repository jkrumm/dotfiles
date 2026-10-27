import { describe, expect, test } from "bun:test"
import { gradeMachine, healthSignature, worst } from "./lib/claude-health.ts"

const u = (id: string, auth_ok = true, age_s = 30) => ({ id, auth_ok, age_s })
const e = (id: string, severity: string, days_left: number | null, expired = false) => ({ id, severity, days_left, expired, refresh_expires_at: days_left === null ? null : 1 })

describe("gradeMachine", () => {
  test("unreachable machine fails", () => {
    expect(gradeMachine("mini", { usage: null, expiry: null, pending: null })[0]).toMatchObject({ check: "reach", state: "fail" })
  })
  test("healthy accounts are ok", () => {
    const rows = gradeMachine("mini", { usage: { accounts: [u("iu"), u("me")] }, expiry: { accounts: [e("iu", "PASS", 20), e("me", "PASS", 20)] }, pending: [] })
    expect(worst(rows)).toBe("ok")
    expect(healthSignature(rows)).toBe("")
  })
  test("logged-out default fails, other warns, both carry the fix", () => {
    const rows = gradeMachine("mini", { usage: { default_account: "iu", accounts: [u("iu", false), u("me", false)] }, expiry: null, pending: null })
    expect(rows.map((r) => r.state)).toEqual(["fail", "warn"])
    expect(rows[0].fix).toBe("claude-relogin iu --machine mini")
  })
  test("login ending soon warns; unreadable item (no date) stays ok", () => {
    const soon = gradeMachine("macbook", { usage: { accounts: [u("iu")] }, expiry: { accounts: [e("iu", "WARN", 6.6)] }, pending: [] })
    expect(soon[0]).toMatchObject({ state: "warn", detail: "login ends in 6.6 d" })
    const unreadable = gradeMachine("mini", { usage: { accounts: [u("iu")] }, expiry: { accounts: [e("iu", "WARN", null)] }, pending: [] })
    expect(unreadable[0].state).toBe("ok")
  })
  test("logged in but a quota sample older than 6 h means the token is rejected", () => {
    const rows = gradeMachine("mini", { usage: { accounts: [u("iu", true, 7 * 3600)] }, expiry: null, pending: [] })
    expect(rows.find((r) => r.check === "quota")).toMatchObject({ state: "warn" })
  })
  test("only asks younger than 24 h count as waiting", () => {
    const rows = gradeMachine("mini", { usage: { accounts: [u("iu")] }, expiry: null, pending: [{ id: "a", ageMs: 25 * 3600_000 }, { id: "b", ageMs: 1000 }] })
    expect(rows.find((r) => r.check === "queue")?.detail).toContain("1 ")
  })
})
