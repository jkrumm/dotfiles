import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { type Decl, type State, compareDigests, converge, loadDecl, parseAutoConf, render, sameSetting, scramMatches, scramVerifier, settingLiteral } from "./pg-cluster.ts"

const ENV = { HOME: "/home/u", USER: "u" }
const REAL = readFileSync(join(import.meta.dir, "..", "config", "postgres", "cluster.yaml"), "utf8")

const MINI = `
server:
  service: postgresql@18
  data_dir: /data
  superuser: \${USER}
  address: { port: "5432", unix_socket_directories: "/tmp, \${HOME}/sock" }
  settings: { shared_buffers: 2GB }
  hba: [local all \${USER} trust, host all all 127.0.0.1/32 scram-sha-256]
  ident: []
roles:
  app: { password: op://v/app/pw, connection_limit: 10 }
  ro: { password: none }
databases:
  appdb:
    owner: app
    locale: { provider: icu, locale: en_US.UTF-8, icu_locale: en-US }
    settings: { TimeZone: Etc/UTC }
    privileges: { app: [CONNECT], ro: [CONNECT] }
    schemas:
      app: { owner: app, privileges: { ro: [USAGE] } }
      public: { owner: pg_database_owner, privileges: { PUBLIC: [USAGE] } }
    default_privileges:
      - { for: app, schema: app, on: tables, to: ro, grant: [SELECT] }
`

const opts = (o: Partial<Parameters<typeof converge>[3]> = {}) => ({ address: false, schemas: true, hbaPath: "/data/pg_hba.conf", identPath: "/data/pg_ident.conf", hbaNow: "", identNow: "", ...o })
const empty = (): State => ({ roles: { u: { super: true, login: true, createdb: true, createrole: true, replication: true, bypassrls: true, inherit: true, connection_limit: -1, verifier: null, member_of: [] } }, databases: {}, auto_conf: {}, running: {} })

describe("loadDecl", () => {
  test("the tracked declaration loads and expands", () => {
    const d = loadDecl(REAL, ENV)
    expect(d.server.superuser).toBe("u")
    expect(d.server.address.unix_socket_directories).toContain("/home/u/.local/state/athena/pgsock")
    expect(Object.keys(d.databases)).toEqual(expect.arrayContaining(["shared", "agent_workflows", "weatherorb", "athena"]))
  })
  test("no app role is a superuser and no two roles share a password", () => {
    const d = loadDecl(REAL, ENV)
    expect(d.roles.u).toBeUndefined()
    const refs = Object.values(d.roles).map((r) => r.password).filter((p) => p !== "none")
    expect(new Set(refs).size).toBe(refs.length)
  })
  test("rejects an undeclared role, a shared password and a wrong privilege", () => {
    expect(() => loadDecl(MINI.replace("privileges: { app: [CONNECT], ro: [CONNECT] }", "privileges: { ghost: [CONNECT] }"), ENV)).toThrow("role ghost is not declared")
    expect(() => loadDecl(MINI.replace("ro: { password: none }", "ro: { password: op://v/app/pw }"), ENV)).toThrow("shared by two roles")
    expect(() => loadDecl(MINI.replace("ro: [USAGE]", "ro: [SELECT]"), ENV)).toThrow("not a schema privilege")
    expect(() => loadDecl(MINI.replace("password: none", "password: hunter2"), ENV)).toThrow("neither none nor an op:// ref")
  })
})

describe("scram", () => {
  test("a verifier matches its own password only", () => {
    const v = scramVerifier("s3cret-Value")
    expect(v).toMatch(/^SCRAM-SHA-256\$4096:[^$]+\$[^:]+:.+$/)
    expect(scramMatches(v, "s3cret-Value")).toBe(true)
    expect(scramMatches(v, "other")).toBe(false)
    expect(scramMatches(null, "s3cret-Value")).toBe(false)
    expect(scramMatches("md5abc", "s3cret-Value")).toBe(false)
  })
  test("matches a verifier Postgres 18 made, and rebuilds it byte for byte from its salt", () => {
    // CREATE ROLE probe PASSWORD 'pencil' on postgresql@18 (password_encryption scram-sha-256)
    const pg = "SCRAM-SHA-256$4096:50LRgmQXjkPuriJOS58Bdw==$YkTJaECofBiFgPtdGzrmVQpoyjuMn7i8/rLuZF7s/gc=:PTVh0MPVRyiRfqHkOhvDA9doYD/6dayBtqLFj6AOfRo="
    expect(scramMatches(pg, "pencil")).toBe(true)
    expect(scramMatches(pg, "pencil2")).toBe(false)
    expect(scramVerifier("pencil", Buffer.from("50LRgmQXjkPuriJOS58Bdw==", "base64"))).toBe(pg)
  })
})

test("parseAutoConf reads ALTER SYSTEM's file", () => {
  expect(parseAutoConf("# Do not edit\nshared_buffers = '4GB'\nTimeZone = 'Europe/Berlin'\nx = 'it''s'\n")).toEqual({ shared_buffers: "4GB", timezone: "Europe/Berlin", x: "it's" })
})

describe("converge", () => {
  const d = loadDecl(MINI, ENV)
  const pw = { app: "app-password-1" }

  test("an empty cluster gets roles, the database, privileges, schemas and settings, in order", () => {
    const p = converge(d, empty(), pw, opts())
    const sql = p.statements.map((s) => s.sql)
    expect(sql[0]).toBe("ALTER SYSTEM SET shared_buffers = '2GB'")
    expect(sql).toContain("CREATE ROLE app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT CONNECTION LIMIT 10")
    expect(sql.indexOf("CREATE DATABASE appdb OWNER app TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER icu ICU_LOCALE 'en-US' LOCALE 'en_US.UTF-8'")).toBeLessThan(sql.indexOf("CREATE SCHEMA app AUTHORIZATION app"))
    expect(sql).toContain("REVOKE CONNECT, TEMPORARY ON DATABASE appdb FROM PUBLIC")
    expect(sql).toContain("GRANT CONNECT ON DATABASE appdb TO ro")
    expect(sql).not.toContain("GRANT CONNECT ON DATABASE appdb TO app") // the owner's privileges are implicit
    expect(sql).not.toContain("CREATE SCHEMA public AUTHORIZATION pg_database_owner") // template0 brings it
    expect(sql).toContain("ALTER DEFAULT PRIVILEGES FOR ROLE app IN SCHEMA app GRANT SELECT ON TABLES TO ro")
    expect(sql).toContain("ALTER DATABASE appdb SET TimeZone = 'Etc/UTC'")
  })

  test("the password is sent as a verifier, never shown, and skipped once it matches", () => {
    const p = converge(d, empty(), pw, opts())
    const set = p.statements.find((s) => s.sql.startsWith("ALTER ROLE app PASSWORD"))!
    expect(set.sql).not.toContain("app-password-1")
    expect(set.shown).toBe("ALTER ROLE app PASSWORD '<scram verifier of op://v/app/pw>'")
    const verifier = set.sql.match(/'(SCRAM[^']+)'/)![1]
    const s = empty()
    s.roles.app = { super: false, login: true, createdb: false, createrole: false, replication: false, bypassrls: false, inherit: true, connection_limit: 10, verifier, member_of: [] }
    expect(converge(d, s, pw, opts()).statements.some((x) => x.sql.startsWith("ALTER ROLE app"))).toBe(false)
  })

  test("a missing secret is drift, not a failure", () => {
    expect(converge(d, empty(), {}, opts()).drift).toContain("role app: op://v/app/pw is not in the secrets cache; password left as it is")
  })

  test("a converged cluster plans nothing; extras are revoked or reported, never dropped", () => {
    const s = empty()
    const verifier = scramVerifier("app-password-1")
    s.roles.app = { super: false, login: true, createdb: false, createrole: false, replication: false, bypassrls: false, inherit: true, connection_limit: 10, verifier, member_of: [] }
    s.roles.ro = { super: false, login: true, createdb: false, createrole: false, replication: false, bypassrls: false, inherit: true, connection_limit: -1, verifier: null, member_of: [] }
    s.roles.stray = { ...s.roles.ro }
    s.auto_conf = { shared_buffers: "2GB" }
    s.databases.appdb = {
      owner: "app", provider: "icu", collate: "en_US.UTF-8", icu_locale: "en-US", settings: { timezone: "Etc/UTC" }, role_settings: {},
      privileges: { ro: ["CONNECT"] },
      schemas: { app: { owner: "app", privileges: { ro: ["USAGE"] } }, public: { owner: "pg_database_owner", privileges: { PUBLIC: ["USAGE"] } } },
      extensions: {}, default_privileges: ["app|app|r|ro|SELECT"],
    }
    s.databases.other = { ...s.databases.appdb }
    const p = converge(d, s, pw, opts())
    expect(p.statements).toEqual([])
    expect(p.drift).toContain("role stray exists but is not declared (left alone)")
    expect(p.drift).toContain("database other exists but is not declared (left alone)")

    s.databases.appdb.privileges.stray = ["CONNECT"]
    s.databases.appdb.schemas.app.privileges.PUBLIC = ["USAGE"]
    const sql = converge(d, s, pw, opts()).statements.map((x) => x.sql)
    expect(sql).toEqual(["REVOKE CONNECT ON DATABASE appdb FROM stray", "REVOKE USAGE ON SCHEMA app FROM PUBLIC"])
  })

  test("address settings and client auth wait for --address", () => {
    const before = converge(d, empty(), pw, opts())
    expect(before.statements.some((s) => s.sql.includes("port"))).toBe(false)
    expect(before.files).toEqual([])
    expect(before.drift.some((x) => x.startsWith("address setting port"))).toBe(true)
    const at = converge(d, empty(), pw, opts({ address: true }))
    expect(at.statements.map((s) => s.sql)).toContain("ALTER SYSTEM SET unix_socket_directories = '/tmp', '/home/u/sock'")
    expect(at.files.map((f) => f.path)).toEqual(["/data/pg_hba.conf", "/data/pg_ident.conf"])
    expect(at.files[0].content).toBe(render(["local all u trust", "host all all 127.0.0.1/32 scram-sha-256"]))
  })

  test("a list setting gets one literal per element and reads back from Postgres's stored form", () => {
    expect(settingLiteral("unix_socket_directories", "/tmp, /home/u/sock")).toBe("'/tmp', '/home/u/sock'")
    expect(settingLiteral("shared_buffers", "2GB")).toBe("'2GB'")
    expect(sameSetting("unix_socket_directories", '"/tmp", "/home/u/sock"', "/tmp, /home/u/sock")).toBe(true)
    expect(sameSetting("unix_socket_directories", '"/tmp, /home/u/sock"', "/tmp, /home/u/sock")).toBe(false)
    const s = empty()
    s.auto_conf = { shared_buffers: "2GB", port: "5432", unix_socket_directories: '"/tmp", "/home/u/sock"' }
    expect(converge(d, s, pw, opts({ address: true })).statements.some((x) => x.sql.startsWith("ALTER SYSTEM"))).toBe(false)
  })

  test("--no-schemas stops at databases (the state a restore starts from)", () => {
    const sql = converge(d, empty(), pw, opts({ schemas: false })).statements.map((s) => s.sql)
    expect(sql.some((s) => s.startsWith("CREATE SCHEMA") || s.startsWith("ALTER DEFAULT"))).toBe(false)
    expect(sql.some((s) => s.startsWith("CREATE DATABASE appdb"))).toBe(true)
  })

  test("an owner change never revokes the new owner's own privileges", () => {
    const s = empty()
    s.databases.appdb = { owner: "u", provider: "icu", collate: "en_US.UTF-8", icu_locale: "en-US", settings: { timezone: "Etc/UTC" }, role_settings: {}, privileges: { app: ["CREATE"], ro: ["CONNECT"] }, schemas: { app: { owner: "u", privileges: { app: ["CREATE", "USAGE"], ro: ["USAGE"] } }, public: { owner: "pg_database_owner", privileges: { PUBLIC: ["USAGE"] } } }, extensions: {}, default_privileges: ["app|app|r|ro|SELECT"] }
    const sql = converge(d, s, pw, opts()).statements.map((x) => x.sql)
    expect(sql).toContain("ALTER DATABASE appdb OWNER TO app")
    expect(sql).toContain("ALTER SCHEMA app OWNER TO app")
    expect(sql.some((x) => x.includes("FROM app"))).toBe(false)
  })

  test("an existing database with another locale is drift, never recreated", () => {
    const s = empty()
    s.databases.appdb = { owner: "app", provider: "libc", collate: "C", icu_locale: null, settings: {}, role_settings: {}, privileges: {}, schemas: {}, extensions: {}, default_privileges: [] }
    const p = converge(d as Decl, s, pw, opts())
    expect(p.drift.some((x) => x.startsWith("database appdb: locale is libc C"))).toBe(true)
    expect(p.statements.some((x) => x.sql.includes("DROP"))).toBe(false)
  })
})

describe("compareDigests", () => {
  const base = { tables: { "a.t": "3 rows, hash 9" }, sequences: { "a.s": "3" }, large_objects: 0, schemas: { a: { owner: "o", privileges: {} } }, extensions: {}, default_privileges: [], relations: { "a.t": "r owner o acl o=arwdDxtm/o" } }

  test("names every difference", () => {
    expect(compareDigests(base, structuredClone(base))).toEqual([])
    const copy = structuredClone(base)
    copy.tables["a.t"] = "2 rows, hash 7"
    copy.sequences["a.s"] = "unset"
    copy.relations["a.t"] = "r owner x acl x=arwdDxtm/x"
    expect(compareDigests(base, copy)).toEqual([
      'table a.t: source "3 rows, hash 9", copy "2 rows, hash 7"',
      'sequence a.s: source "3", copy "unset"',
      'relation a.t: source "r owner o acl o=arwdDxtm/o", copy "r owner x acl x=arwdDxtm/x"',
    ])
  })

  test("a live source may run a sequence ahead of the copy, never behind it; tables stay exact", () => {
    const behind = structuredClone(base)
    behind.sequences["a.s"] = "2"
    expect(compareDigests(base, behind, true)).toEqual([])
    expect(compareDigests(base, behind, false)).toEqual(['sequence a.s: source "3", copy "2"'])
    const ahead = structuredClone(base)
    ahead.sequences["a.s"] = "4"
    expect(compareDigests(base, ahead, true)).toEqual(['sequence a.s: source "3", copy "4"'])
    const rows = structuredClone(base)
    rows.tables["a.t"] = "4 rows, hash 1"
    expect(compareDigests(base, rows, true)).toHaveLength(1)
  })
})
