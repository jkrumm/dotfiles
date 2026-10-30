import { expect, test } from "bun:test"
import { loadRegistry, validateRegistry } from "./registry"

const svc = (over: Record<string, unknown> = {}) => ({ name: "argo", url: "http://127.0.0.1:7737/api/health", title: "Argo", ...over })
const reg = (services: unknown[], ...port: unknown[]) => ({ port: port.length > 0 ? port[0] : 8795, services })

test("the committed registry.json is valid", () => {
  const r = loadRegistry()
  expect(r.port).toBe(8795)
  expect(r.services.length).toBeGreaterThan(0)
})

test("a valid registry passes, interval optional", () => {
  expect(validateRegistry(reg([svc(), svc({ name: "b-2", interval: 60 })])).services).toHaveLength(2)
})

test("duplicate name is rejected", () => {
  expect(() => validateRegistry(reg([svc(), svc()]))).toThrow(/duplicate name/)
})

test("bad names are rejected", () => {
  for (const name of ["Argo", "-argo", "ar go", "ar/go", "ar.go", "", "ärgo", 7]) {
    expect(() => validateRegistry(reg([svc({ name })]))).toThrow(/name must match/)
  }
})

test("an explicit default port on loopback is accepted", () => {
  expect(() => validateRegistry(reg([svc({ url: "http://127.0.0.1:80/health" })]))).not.toThrow()
})

test("non-loopback or oddly spelled urls are rejected", () => {
  for (const url of [
    "http://example.com:80/",
    "http://192.168.1.5:80/",
    "https://127.0.0.1:7737/",
    "http://localhost:7737/",
    "http://127.0.0.1/",
    "http://127.1:7737/",
    "http://user:pw@127.0.0.1:7737/",
    "http://127.0.0.1.evil.example:7737/",
    "http://127.0.0.1:7737@evil.example/",
    "",
    42,
  ]) {
    expect(() => validateRegistry(reg([svc({ url })]))).toThrow(/url must be/)
  }
})

test("missing or invalid port is rejected", () => {
  for (const port of [undefined, "8795", 0, 70000, 1.5]) {
    expect(() => validateRegistry(reg([svc()], port))).toThrow(/port:/)
  }
})

test("missing title, bad interval and empty services are rejected", () => {
  expect(() => validateRegistry(reg([svc({ title: "" })]))).toThrow(/title/)
  expect(() => validateRegistry(reg([svc({ interval: 5 })]))).toThrow(/interval/)
  expect(() => validateRegistry(reg([]))).toThrow(/services/)
  expect(() => validateRegistry(null)).toThrow(/invalid registry/)
})

test("every problem is reported in one error", () => {
  expect(() => validateRegistry(reg([svc({ name: "A" }), svc({ url: "http://x/" })], 0))).toThrow(/port:[\s\S]*name must match[\s\S]*url must be/)
})
