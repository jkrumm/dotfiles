// The mode mark and forecast words of the Herdr mods jk-status (bar chip) and jk-details (usage popup), on fixture
// `claude-account status --json` rows. The mods import host modules (herdr, gpui-kit, gpui-base) that exist only inside
// the app, so they are stubbed here; the functions under test are pure.
import { describe, expect, mock, test } from "bun:test"

const stubClass = class {}
const stub = () => new Proxy(() => stub(), { get: () => stub() })
mock.module("gpui-kit", () => ({ View: stubClass, div: stub, svg: stub }))
mock.module("gpui-base", () => ({ h_flex: stub, v_flex: stub }))
mock.module("herdr", () => ({
  theme: stub, run: stub, window: stub, exec: stub, hc: stub, shared: stub, setShared: stub, openOverlay: stub,
  closeOverlay: stub, props: stub,
}))

const status = await import("../config/herdr-app/mods/jk-status/main.js")
const details = await import("../config/herdr-app/mods/jk-details/main.js")

// status --json rows, reduced to what the mods read
const mode = (kind: string, extra: Record<string, unknown> = {}) => ({ kind, for: null, until: null, until_at: null, expired: false, ...extra })
const rows = [
  { id: "iu", mode: mode("reserve", { for: "fable" }), forecast: { weekly_at_reset: 20, full_at: null, waste_percent: 80 } },
  { id: "me", mode: mode("normal"), forecast: { weekly_at_reset: 100, full_at: "2026-11-24T04:03:36.978Z", waste_percent: 0 } },
  { id: "me2", mode: mode("drain", { until: "reset" }), forecast: { weekly_at_reset: 0, full_at: null, waste_percent: 100 } },
]

describe.each([
  ["jk-status", status],
  ["jk-details", details],
])("%s", (_name, mod) => {
  test("one mark per mode: drain ↓, reserve ◆, paused ‖, normal none", () => {
    expect(mod.modeMark(rows[2])).toBe("↓")
    expect(mod.modeMark(rows[0])).toBe("◆")
    expect(mod.modeMark({ mode: mode("paused") })).toBe("‖")
    expect(mod.modeMark(rows[1])).toBe("")
  })

  test("an ended override, an unknown kind and a missing mode show no mark", () => {
    expect(mod.modeMark({ mode: mode("drain", { expired: true }) })).toBe("")
    expect(mod.modeMark({ mode: mode("<script>") })).toBe("")
    expect(mod.modeMark({})).toBe("")
    expect(mod.modeMark(undefined)).toBe("")
  })

  test("forecast in words only for an account that will not be full at its reset", () => {
    expect(mod.forecastWords(rows[2])).toBe("ends the week at 0%, 100% unused at reset")
    expect(mod.forecastWords(rows[0])).toBe("ends the week at 20%, 80% unused at reset")
    expect(mod.forecastWords(rows[1])).toBeNull()
    expect(mod.forecastWords({ forecast: null })).toBeNull()
    expect(mod.forecastWords({})).toBeNull()
  })
})

test("jk-details names the mode in words", () => {
  expect(details.modeWords(rows[2])).toBe("drain until reset")
  expect(details.modeWords(rows[0])).toBe("reserve for fable")
  expect(details.modeWords(rows[1])).toBeNull()
})

test("jk-status merges status rows into the usage rows by id and leaves unmatched rows unchanged", () => {
  const usage = [{ id: "iu", five_hour: null, seven_day: 20 }, { id: "me2", five_hour: 4, seven_day: 0 }, { id: "x", five_hour: 1, seven_day: 1 }]
  const merged = status.withStatus(usage, rows)
  expect(merged[0]).toMatchObject({ id: "iu", seven_day: 20, mode: { kind: "reserve" } })
  expect(merged[1]).toMatchObject({ id: "me2", five_hour: 4, mode: { kind: "drain" } })
  expect(merged[2]).toEqual(usage[2])
  expect(status.withStatus(usage, undefined)).toEqual(usage)
})

test("the pool is unchanged by the extra fields", () => {
  const usage = [{ id: "iu", plan: "ultra", seven_day: 20 }, { id: "me", plan: "max", seven_day: 4 }]
  expect(status.pool(status.withStatus(usage, rows))).toBe(status.pool(usage))
})
