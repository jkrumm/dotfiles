#!/usr/bin/env bun
// The mini's one Postgres as code: config/postgres/cluster.yaml is the declaration,
// this tool converges a server onto it and proves copies. docs/postgres.md.
//
//   (every verb: --port N, and --socket-dir DIR --data-dir DIR to point it at a scratch cluster)
//   pg-cluster plan     [--port N] [--address] [--no-schemas]   what apply would do (no secrets shown)
//   pg-cluster apply    [--port N] [--address] [--no-schemas]   converge; exit 1 on a failed statement
//       --no-schemas: roles, databases and their privileges and settings only, the state a restore
//       starts from (a restore brings schemas, extensions and default privileges itself).
//       --roles-only: settings and roles, no database touched (roles an app needs before the cutover).
//   pg-cluster snapshot [--port N] [--host DIR|IP] [--user U] [--password-ref R] [--db D]...
//                                                                normalized catalog JSON (equality proofs)
//   pg-cluster copy --db SRC [--as DST] --from-host H --from-port P --from-user U [--from-password-ref R]
//                   [--port N] [--keep-dir DIR] [--live]
//       one REPEATABLE READ snapshot on the source: pg_dump --snapshot of it, and per table
//       count(*) + a content hash, sequences, large objects, schema owners and ACLs, all read
//       inside it; restore into DST (which must have no user tables), read the same from DST,
//       compare. Exit 1 on any difference. The dump file stays in --keep-dir. --live: the source
//       is being written, so a sequence may read lower in the copy (see compareDigests).
//
// The superuser connects over the unix socket in /tmp (trust for the OS user only, 0700).
// Passwords are 1Password refs resolved through `secrets-run read`; a plaintext never reaches
// the server or argv: apply sends a SCRAM verifier it computed, and skips a role whose
// stored verifier already matches.

import { SQL } from "bun"
import { createHash, createHmac, pbkdf2Sync, randomBytes } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir, userInfo } from "node:os"
import { join } from "node:path"

const CONFIG = join(import.meta.dir, "..", "config", "postgres", "cluster.yaml")
const PG_BIN = "/opt/homebrew/opt/postgresql@18/bin"
const IDENT = /^[a-z_][a-z0-9_]*$/

// ---------------------------------------------------------------- declaration

export type Priv = string
export type DefaultPriv = { for: string; schema?: string; on: "tables" | "sequences" | "schemas" | "functions" | "types"; to: string; grant: Priv[] }
export type SchemaDecl = { owner: string; privileges?: Record<string, Priv[]> }
export type DbDecl = {
  owner: string
  locale: { provider: "libc" | "icu"; locale: string; icu_locale?: string }
  settings?: Record<string, string>
  privileges?: Record<string, Priv[]>
  role_settings?: Record<string, Record<string, string>>
  extensions?: Record<string, { schema: string }>
  schemas?: Record<string, SchemaDecl>
  default_privileges?: DefaultPriv[]
}
export type RoleDecl = { password: string; connection_limit?: number }
export type Decl = {
  server: {
    service: string
    data_dir: string
    superuser: string
    address: Record<string, string>
    settings: Record<string, string>
    hba: string[]
    ident: string[]
  }
  roles: Record<string, RoleDecl>
  databases: Record<string, DbDecl>
}

const PRIVS: Record<string, string[]> = {
  database: ["CONNECT", "CREATE", "TEMPORARY"],
  schema: ["USAGE", "CREATE"],
  tables: ["SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN"],
  sequences: ["SELECT", "UPDATE", "USAGE"],
  schemas: ["USAGE", "CREATE"],
  functions: ["EXECUTE"],
  types: ["USAGE"],
}
const DEFACL_TYPE: Record<string, string> = { tables: "r", sequences: "S", functions: "f", types: "T", schemas: "n" }

export function expand(text: string, env: { HOME: string; USER: string }): string {
  return text.replaceAll("${HOME}", env.HOME).replaceAll("${USER}", env.USER)
}

export function loadDecl(text: string, env = { HOME: homedir(), USER: userInfo().username }): Decl {
  const d = Bun.YAML.parse(expand(text, env)) as Decl
  const errors: string[] = []
  const role = (r: string, where: string) => {
    if (r === "PUBLIC" || r === "pg_database_owner" || r === d.server.superuser) return
    if (!d.roles[r]) errors.push(`${where}: role ${r} is not declared`)
  }
  const privs = (list: Priv[], kind: string, where: string) => {
    for (const p of list) if (p !== "ALL" && !PRIVS[kind].includes(p)) errors.push(`${where}: ${p} is not a ${kind} privilege`)
  }
  for (const [name, r] of Object.entries(d.roles)) {
    if (!IDENT.test(name)) errors.push(`role ${name}: not a plain identifier`)
    if (r.password !== "none" && !/^op:\/\/[^/]+\/[^/]+\/[^/]+$/.test(r.password)) errors.push(`role ${name}: password is neither none nor an op:// ref`)
  }
  const refs = Object.values(d.roles).map((r) => r.password).filter((p) => p !== "none")
  for (const p of new Set(refs)) if (refs.filter((x) => x === p).length > 1) errors.push(`password ${p} is shared by two roles`)
  for (const [name, db] of Object.entries(d.databases)) {
    if (!IDENT.test(name)) errors.push(`database ${name}: not a plain identifier`)
    role(db.owner, `database ${name} owner`)
    for (const [g, p] of Object.entries(db.privileges ?? {})) { role(g, `database ${name} privileges`); privs(p, "database", `database ${name}`) }
    for (const r of Object.keys(db.role_settings ?? {})) role(r, `database ${name} role_settings`)
    for (const [s, sd] of Object.entries(db.schemas ?? {})) {
      if (!IDENT.test(s)) errors.push(`schema ${name}.${s}: not a plain identifier`)
      role(sd.owner, `schema ${name}.${s} owner`)
      for (const [g, p] of Object.entries(sd.privileges ?? {})) { role(g, `schema ${name}.${s}`); privs(p, "schema", `schema ${name}.${s}`) }
    }
    for (const dp of db.default_privileges ?? []) {
      role(dp.for, `default privileges in ${name}`); role(dp.to, `default privileges in ${name}`)
      if (!DEFACL_TYPE[dp.on]) errors.push(`default privileges in ${name}: unknown object type ${dp.on}`)
      else privs(dp.grant, dp.on, `default privileges in ${name}`)
    }
  }
  if (errors.length) throw new Error(`cluster.yaml:\n  ${errors.join("\n  ")}`)
  return d
}

const expandAll = (list: Priv[], kind: string) => (list.includes("ALL") ? PRIVS[kind] : list)

// ---------------------------------------------------------------- SCRAM

export function scramVerifier(password: string, salt = randomBytes(16), iterations = 4096): string {
  const salted = pbkdf2Sync(password, salt, iterations, 32, "sha256")
  const clientKey = createHmac("sha256", salted).update("Client Key").digest()
  const storedKey = createHash("sha256").update(clientKey).digest()
  const serverKey = createHmac("sha256", salted).update("Server Key").digest()
  return `SCRAM-SHA-256$${iterations}:${salt.toString("base64")}$${storedKey.toString("base64")}:${serverKey.toString("base64")}`
}

// True when the stored verifier was made from this password. Only printable ASCII is checked
// (SASLprep leaves it unchanged); anything else reads as "no match" and gets a fresh verifier.
export function scramMatches(stored: string | null, password: string): boolean {
  const m = stored?.match(/^SCRAM-SHA-256\$(\d+):([^$]+)\$([^:]+):(.+)$/)
  if (!m || !/^[\x20-\x7e]+$/.test(password)) return false
  return scramVerifier(password, Buffer.from(m[2], "base64"), Number(m[1])) === stored
}

// ---------------------------------------------------------------- live state

export type Grants = Record<string, string[]> // grantee (PUBLIC for 0) -> sorted privileges, owner left out
export type DbState = {
  owner: string
  provider: string
  collate: string
  icu_locale: string | null
  settings: Record<string, string>
  role_settings: Record<string, Record<string, string>>
  privileges: Grants
  schemas: Record<string, { owner: string; privileges: Grants }>
  extensions: Record<string, { schema: string; version: string }>
  default_privileges: string[] // "for|schema|on|to|PRIV,PRIV"
}
export type State = {
  roles: Record<string, { super: boolean; login: boolean; createdb: boolean; createrole: boolean; replication: boolean; bypassrls: boolean; inherit: boolean; connection_limit: number; verifier: string | null; member_of: string[] }>
  databases: Record<string, DbState>
  auto_conf: Record<string, string> // lower-cased name -> value from postgresql.auto.conf
  running: Record<string, string> // lower-cased name -> current_setting
}

const PROVIDER: Record<string, string> = { c: "libc", i: "icu", b: "builtin" }

function grantsFrom(rows: { grantee: string; priv: string }[]): Grants {
  const g: Grants = {}
  for (const r of rows) (g[r.grantee] ??= []).push(r.priv)
  for (const k of Object.keys(g)) g[k].sort()
  return g
}

function settingsFrom(config: string[] | null): Record<string, string> {
  const out: Record<string, string> = {}
  for (const kv of config ?? []) {
    const i = kv.indexOf("=")
    out[kv.slice(0, i).toLowerCase()] = kv.slice(i + 1)
  }
  return out
}

export function parseAutoConf(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of text.split("\n")) {
    const m = line.match(/^\s*([A-Za-z_.]+)\s*=\s*'((?:[^']|'')*)'/)
    if (m) out[m[1].toLowerCase()] = m[2].replaceAll("''", "'")
  }
  return out
}

export type Conn = { host: string; port: number; user: string; password?: string }

export function connect(c: Conn, database: string): SQL {
  const base = { username: c.user, database, max: 1, idleTimeout: 30, connectionTimeout: 15 }
  if (c.host.startsWith("/")) return new SQL({ ...base, path: join(c.host, `.s.PGSQL.${c.port}`) } as never)
  return new SQL({ ...base, hostname: c.host, port: c.port, password: c.password } as never)
}

async function readDb(sql: SQL): Promise<Omit<DbState, "owner" | "provider" | "collate" | "icu_locale" | "settings" | "role_settings" | "privileges">> {
  const schemas: DbState["schemas"] = {}
  const srows = await sql`
    SELECT n.nspname AS name, pg_get_userbyid(n.nspowner) AS owner,
           coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') AS grantee, a.privilege_type AS priv
      FROM pg_namespace n
      LEFT JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a ON a.grantee <> n.nspowner
     WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'`
  for (const r of srows) {
    schemas[r.name] ??= { owner: r.owner, privileges: {} }
    if (r.grantee && r.priv) (schemas[r.name].privileges[r.grantee] ??= []).push(r.priv)
  }
  for (const s of Object.values(schemas)) for (const k of Object.keys(s.privileges)) s.privileges[k].sort()
  const extensions: DbState["extensions"] = {}
  for (const r of await sql`SELECT extname, extnamespace::regnamespace::text AS schema, extversion FROM pg_extension WHERE extname <> 'plpgsql'`)
    extensions[r.extname] = { schema: r.schema, version: r.extversion }
  const default_privileges = (
    await sql`
      SELECT pg_get_userbyid(d.defaclrole) AS for, coalesce(nullif(d.defaclnamespace, 0)::regnamespace::text, '') AS schema,
             d.defaclobjtype::text AS t, coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') AS grantee,
             string_agg(a.privilege_type, ',' ORDER BY a.privilege_type) AS privs
        FROM pg_default_acl d, aclexplode(d.defaclacl) a
       WHERE a.grantee <> d.defaclrole
       GROUP BY 1, 2, 3, 4`
  ).map((r: Record<string, string>) => `${r.for}|${r.schema}|${r.t}|${r.grantee}|${r.privs}`).sort()
  return { schemas, extensions, default_privileges }
}

export async function readState(c: Conn, dataDir: string | null, dbs: string[] | "all"): Promise<State> {
  const sql = connect(c, "postgres")
  try {
    const roles: State["roles"] = {}
    for (const r of await sql`
      SELECT a.rolname, a.rolsuper, a.rolcanlogin, a.rolcreatedb, a.rolcreaterole, a.rolreplication, a.rolbypassrls,
             a.rolinherit, a.rolconnlimit, a.rolpassword,
             coalesce((SELECT array_agg(b.rolname ORDER BY b.rolname) FROM pg_auth_members m JOIN pg_roles b ON b.oid = m.roleid WHERE m.member = a.oid), '{}') AS member_of
        FROM pg_authid a WHERE a.rolname !~ '^pg_'`)
      roles[r.rolname] = { super: r.rolsuper, login: r.rolcanlogin, createdb: r.rolcreatedb, createrole: r.rolcreaterole, replication: r.rolreplication, bypassrls: r.rolbypassrls, inherit: r.rolinherit, connection_limit: r.rolconnlimit, verifier: r.rolpassword, member_of: r.member_of }
    const databases: State["databases"] = {}
    const drows = await sql`
      SELECT d.datname, pg_get_userbyid(d.datdba) AS owner, d.datlocprovider::text AS provider, d.datcollate, d.datlocale,
             (SELECT setconfig FROM pg_db_role_setting s WHERE s.setdatabase = d.oid AND s.setrole = 0) AS settings
        FROM pg_database d WHERE NOT d.datistemplate`
    const acl = await sql`
      SELECT d.datname, coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') AS grantee, a.privilege_type AS priv
        FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
       WHERE a.grantee <> d.datdba`
    const rs = await sql`
      SELECT d.datname, pg_get_userbyid(s.setrole) AS role, s.setconfig
        FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase WHERE s.setrole <> 0`
    for (const r of drows) {
      databases[r.datname] = {
        owner: r.owner, provider: PROVIDER[r.provider] ?? r.provider, collate: r.datcollate, icu_locale: r.datlocale,
        settings: settingsFrom(r.settings), role_settings: {},
        privileges: grantsFrom(acl.filter((a: { datname: string }) => a.datname === r.datname)),
        schemas: {}, extensions: {}, default_privileges: [],
      }
    }
    for (const r of rs) if (databases[r.datname]) databases[r.datname].role_settings[r.role] = settingsFrom(r.setconfig)
    const running: Record<string, string> = {}
    for (const r of await sql`SELECT name, current_setting(name) AS v FROM pg_settings`) running[r.name.toLowerCase()] = r.v
    for (const name of Object.keys(databases)) {
      if (dbs !== "all" && !dbs.includes(name)) continue
      const dsql = connect(c, name)
      try { Object.assign(databases[name], await readDb(dsql)) } finally { await dsql.close() }
    }
    const autoPath = dataDir ? join(dataDir, "postgresql.auto.conf") : null
    const auto_conf = autoPath && existsSync(autoPath) ? parseAutoConf(readFileSync(autoPath, "utf8")) : {}
    return { roles, databases, auto_conf, running }
  } finally {
    await sql.close()
  }
}

// ---------------------------------------------------------------- converge

export type Stmt = { db: string; sql: string; shown?: string; outside_tx?: boolean }
export type Plan = { statements: Stmt[]; drift: string[]; files: { path: string; content: string }[]; restart: string[] }
export type Opts = { address: boolean; schemas: boolean; rolesOnly?: boolean; hbaPath: string; identPath: string; hbaNow: string; identNow: string }

const q = (s: string) => `'${s.replaceAll("'", "''")}'`
const id = (s: string) => (s === "PUBLIC" ? "PUBLIC" : IDENT.test(s) ? s : `"${s.replaceAll('"', '""')}"`)

function diffGrants(want: Record<string, Priv[]>, have: Grants, kind: string) {
  const grant: [string, string[]][] = []
  const revoke: [string, string[]][] = []
  const all = new Set([...Object.keys(want), ...Object.keys(have)])
  for (const g of all) {
    const w = new Set(expandAll(want[g] ?? [], kind))
    const h = new Set(have[g] ?? [])
    const add = [...w].filter((p) => !h.has(p)).sort()
    const del = [...h].filter((p) => !w.has(p)).sort()
    if (add.length) grant.push([g, add])
    if (del.length) revoke.push([g, del])
  }
  return { grant, revoke }
}

// List settings take one literal per element: `= '/tmp, /x'` is ONE directory named "/tmp, /x"
// (the 2026-11-14 drill's failed start). Postgres stores them as '"/tmp", "/x"', so compare elements.
const LIST_SETTINGS = new Set(["unix_socket_directories", "search_path", "shared_preload_libraries", "local_preload_libraries", "session_preload_libraries", "temp_tablespaces"])
const listItems = (v: string) => v.split(",").map((x) => x.trim().replace(/^"(.*)"$/, "$1")).filter(Boolean)
export const settingLiteral = (k: string, v: string) => (LIST_SETTINGS.has(k.toLowerCase()) ? listItems(v).map(q).join(", ") : q(v))
export function sameSetting(k: string, have: string | undefined, want: string): boolean {
  if (have === undefined) return false
  return LIST_SETTINGS.has(k.toLowerCase()) ? listItems(have).join("\n") === listItems(want).join("\n") : have === want
}

// The owner's own privileges are implicit (aclexplode lists them under the owner, readState drops them).
const withoutOwner = (g: Record<string, Priv[]> | undefined, owner: string) => Object.fromEntries(Object.entries(g ?? {}).filter(([k]) => k !== owner))

export function render(lines: string[]): string {
  return `# Managed by dotfiles config/postgres/cluster.yaml (make pg-apply). Edits here are overwritten.\n${lines.join("\n")}\n`
}

export function converge(d: Decl, s: State, passwords: Record<string, string | undefined>, o: Opts): Plan {
  const p: Plan = { statements: [], drift: [], files: [], restart: [] }
  const su = d.server.superuser
  const at = (db: string, sql: string, extra: Partial<Stmt> = {}) => p.statements.push({ db, sql, ...extra })

  // server settings: ALTER SYSTEM writes postgresql.auto.conf; compare against that file
  const settings = { ...d.server.settings, ...(o.address ? d.server.address : {}) }
  for (const [k, v] of Object.entries(settings)) if (!sameSetting(k, s.auto_conf[k.toLowerCase()], v)) at("postgres", `ALTER SYSTEM SET ${k} = ${settingLiteral(k, v)}`, { outside_tx: true })
  if (!o.address) for (const [k, v] of Object.entries(d.server.address)) if (!sameSetting(k, s.auto_conf[k.toLowerCase()] ?? s.running[k.toLowerCase()], v)) p.drift.push(`address setting ${k} is not ${v} yet (applied by the cutover: pg-apply --address)`)

  // client auth files: only with the address, they change who can log in over TCP
  const hba = render(d.server.hba)
  const ident = render(d.server.ident)
  if (o.address) {
    if (o.hbaNow !== hba) p.files.push({ path: o.hbaPath, content: hba })
    if (o.identNow !== ident) p.files.push({ path: o.identPath, content: ident })
  } else if (o.hbaNow !== hba || o.identNow !== ident) p.drift.push("pg_hba.conf / pg_ident.conf differ from the declaration (applied by the cutover: pg-apply --address)")

  // roles
  for (const [name, r] of Object.entries(d.roles)) {
    const h = s.roles[name]
    const limit = r.connection_limit ?? -1
    if (!h) at("postgres", `CREATE ROLE ${id(name)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT CONNECTION LIMIT ${limit}`)
    else {
      const attrs: string[] = []
      if (!h.login) attrs.push("LOGIN")
      if (h.super) attrs.push("NOSUPERUSER")
      if (h.createdb) attrs.push("NOCREATEDB")
      if (h.createrole) attrs.push("NOCREATEROLE")
      if (h.replication) attrs.push("NOREPLICATION")
      if (h.bypassrls) attrs.push("NOBYPASSRLS")
      if (!h.inherit) attrs.push("INHERIT")
      if (h.connection_limit !== limit) attrs.push(`CONNECTION LIMIT ${limit}`)
      if (attrs.length) at("postgres", `ALTER ROLE ${id(name)} ${attrs.join(" ")}`)
      if (h.member_of.length) p.drift.push(`role ${name} is a member of ${h.member_of.join(", ")} (not declared)`)
    }
    const verifier = h?.verifier ?? null
    if (r.password === "none") {
      if (verifier) at("postgres", `ALTER ROLE ${id(name)} PASSWORD NULL`)
    } else {
      const pw = passwords[name]
      if (pw === undefined) p.drift.push(`role ${name}: ${r.password} is not in the secrets cache; password left as it is`)
      else if (!scramMatches(verifier, pw)) at("postgres", `ALTER ROLE ${id(name)} PASSWORD ${q(scramVerifier(pw))}`, { shown: `ALTER ROLE ${id(name)} PASSWORD '<scram verifier of ${r.password}>'` })
    }
  }
  for (const name of Object.keys(s.roles)) if (!d.roles[name] && name !== su) p.drift.push(`role ${name} exists but is not declared (left alone)`)
  if (o.rolesOnly) return p

  // databases
  for (const [name, db] of Object.entries(d.databases)) {
    const h = s.databases[name]
    if (!h) {
      const loc = db.locale.provider === "icu" ? `LOCALE_PROVIDER icu ICU_LOCALE ${q(db.locale.icu_locale ?? "und")} LOCALE ${q(db.locale.locale)}` : `LOCALE_PROVIDER libc LOCALE ${q(db.locale.locale)}`
      at("postgres", `CREATE DATABASE ${id(name)} OWNER ${id(db.owner)} TEMPLATE template0 ENCODING 'UTF8' ${loc}`, { outside_tx: true })
    } else {
      if (h.owner !== db.owner) at("postgres", `ALTER DATABASE ${id(name)} OWNER TO ${id(db.owner)}`)
      const wantIcu = db.locale.provider === "icu" ? (db.locale.icu_locale ?? "und") : null
      if (h.provider !== db.locale.provider || h.collate !== db.locale.locale || (wantIcu && h.icu_locale !== wantIcu))
        p.drift.push(`database ${name}: locale is ${h.provider} ${h.collate}${h.icu_locale ? ` ${h.icu_locale}` : ""}, declared ${db.locale.provider} ${db.locale.locale}${wantIcu ? ` ${wantIcu}` : ""} (never recreated by apply)`)
    }
    // the owner's own privileges are implicit; PUBLIC's defaults (CONNECT, TEMPORARY) are revoked unless declared
    // the new owner's earlier grants become its implicit ones with the owner change: never revoke them
    const have = withoutOwner(h?.privileges ?? { PUBLIC: ["CONNECT", "TEMPORARY"] }, db.owner)
    const { grant, revoke } = diffGrants(withoutOwner(db.privileges, db.owner), have, "database")
    for (const [g, ps] of revoke) at("postgres", `REVOKE ${ps.join(", ")} ON DATABASE ${id(name)} FROM ${id(g)}`)
    for (const [g, ps] of grant) at("postgres", `GRANT ${ps.join(", ")} ON DATABASE ${id(name)} TO ${id(g)}`)
    for (const [k, v] of Object.entries(db.settings ?? {})) if (h?.settings[k.toLowerCase()] !== v) at("postgres", `ALTER DATABASE ${id(name)} SET ${k} = ${q(v)}`)
    for (const k of Object.keys(h?.settings ?? {})) if (!Object.keys(db.settings ?? {}).some((x) => x.toLowerCase() === k)) p.drift.push(`database ${name}: setting ${k} is set but not declared`)
    for (const [r, kv] of Object.entries(db.role_settings ?? {}))
      for (const [k, v] of Object.entries(kv)) if (h?.role_settings[r]?.[k.toLowerCase()] !== v) at("postgres", `ALTER ROLE ${id(r)} IN DATABASE ${id(name)} SET ${k} = ${q(v)}`)
    if (!o.schemas) continue

    for (const [sn, sd] of Object.entries(db.schemas ?? {})) {
      // a new database already has public (template0's), owned by pg_database_owner
      const hs = h?.schemas[sn] ?? (sn === "public" ? { owner: "pg_database_owner", privileges: { PUBLIC: ["USAGE"] } } : undefined)
      if (!hs) at(name, `CREATE SCHEMA ${id(sn)} AUTHORIZATION ${id(sd.owner)}`)
      else if (hs.owner !== sd.owner) at(name, `ALTER SCHEMA ${id(sn)} OWNER TO ${id(sd.owner)}`)
      const base: Grants = withoutOwner(hs?.privileges ?? (sn === "public" ? { PUBLIC: ["USAGE"] } : {}), sd.owner)
      const { grant, revoke } = diffGrants(withoutOwner(sd.privileges, sd.owner), base, "schema")
      for (const [g, ps] of revoke) at(name, `REVOKE ${ps.join(", ")} ON SCHEMA ${id(sn)} FROM ${id(g)}`)
      for (const [g, ps] of grant) at(name, `GRANT ${ps.join(", ")} ON SCHEMA ${id(sn)} TO ${id(g)}`)
    }
    for (const [ext, e] of Object.entries(db.extensions ?? {})) {
      const he = h?.extensions[ext]
      if (!he) at(name, `CREATE EXTENSION IF NOT EXISTS ${id(ext)} SCHEMA ${id(e.schema)}`)
      else if (he.schema !== e.schema) p.drift.push(`database ${name}: extension ${ext} is in schema ${he.schema}, declared ${e.schema}`)
    }
    for (const ext of Object.keys(h?.extensions ?? {})) if (!db.extensions?.[ext]) p.drift.push(`database ${name}: extension ${ext} is installed but not declared`)
    const haveDef = new Set(h?.default_privileges ?? [])
    const wantDef = new Set<string>()
    for (const dp of db.default_privileges ?? []) {
      const privs = [...expandAll(dp.grant, dp.on)].sort()
      const key = `${dp.for}|${dp.schema ?? ""}|${DEFACL_TYPE[dp.on]}|${dp.to}|${privs.join(",")}`
      wantDef.add(key)
      if (!haveDef.has(key)) at(name, `ALTER DEFAULT PRIVILEGES FOR ROLE ${id(dp.for)}${dp.schema ? ` IN SCHEMA ${id(dp.schema)}` : ""} GRANT ${privs.join(", ")} ON ${dp.on.toUpperCase()} TO ${id(dp.to)}`)
    }
    for (const k of haveDef) if (!wantDef.has(k)) p.drift.push(`database ${name}: default privilege ${k} is not declared`)
  }
  for (const name of Object.keys(s.databases)) if (!d.databases[name]) p.drift.push(`database ${name} exists but is not declared (left alone)`)
  return p
}

// ---------------------------------------------------------------- snapshot (equality proofs)

export async function snapshot(c: Conn, dbs: string[] | "all"): Promise<unknown> {
  const s = await readState(c, null, dbs)
  const roles = Object.fromEntries(
    Object.entries(s.roles).sort(([a], [b]) => a.localeCompare(b)).map(([n, r]) => [n, { ...r, verifier: r.verifier ? "set" : "none" }]),
  )
  const out: Record<string, unknown> = { roles, databases: {} }
  const sql0 = connect(c, "postgres")
  const dbNames = Object.keys(s.databases).filter((n) => dbs === "all" || dbs.includes(n)).sort()
  await sql0.close()
  for (const n of dbNames) {
    const sql = connect(c, n)
    try {
      const [rel] = await sql`
        SELECT count(*)::int AS n, md5(coalesce(string_agg(format('%s.%s|%s|%s|%s', ns.nspname, c.relname, c.relkind, pg_get_userbyid(c.relowner), c.relacl::text), E'\n' ORDER BY ns.nspname, c.relname), '')) AS digest
          FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
         WHERE ns.nspname !~ '^pg_' AND ns.nspname <> 'information_schema'`
      ;(out.databases as Record<string, unknown>)[n] = { ...s.databases[n], relations: rel }
    } finally {
      await sql.close()
    }
  }
  return out
}

// ---------------------------------------------------------------- copy with proof

type Digest = { tables: Record<string, string>; sequences: Record<string, string>; large_objects: number; schemas: DbState["schemas"]; extensions: DbState["extensions"]; default_privileges: string[]; relations: Record<string, string> }

async function digest(tx: SQL): Promise<Digest> {
  // Row text depends on these; pin them so both clusters print rows identically.
  await tx`SELECT set_config('TimeZone', 'UTC', true), set_config('DateStyle', 'ISO, MDY', true), set_config('IntervalStyle', 'postgres', true), set_config('extra_float_digits', '3', true), set_config('bytea_output', 'hex', true)`
  const tables: Record<string, string> = {}
  const list = await tx`
    SELECT format('%I.%I', n.nspname, c.relname) AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'r' AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' ORDER BY 1`
  for (const { t } of list) {
    const [r] = await tx.unsafe(`SELECT count(*)::text AS c, coalesce(sum(hashtextextended(x::text, 0)::numeric), 0)::text AS h FROM ONLY ${t} x`)
    tables[t] = `${r.c} rows, hash ${r.h}`
  }
  const sequences: Record<string, string> = {}
  for (const r of await tx`SELECT format('%I.%I', schemaname, sequencename) AS s, coalesce(last_value::text, 'unset') AS v FROM pg_sequences`) sequences[r.s] = r.v
  const [lo] = await tx`SELECT count(*)::int AS n FROM pg_largeobject_metadata`
  const db = await readDb(tx)
  const relations: Record<string, string> = {}
  for (const r of await tx`
    SELECT format('%I.%I', ns.nspname, c.relname) AS rel,
           -- NULL means the default ACL; an explicit owner-only ACL means the same and pg_dump drops it
           format('%s owner %s acl %s', c.relkind, pg_get_userbyid(c.relowner),
             (SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(coalesce(c.relacl, acldefault((CASE c.relkind WHEN 'S' THEN 's' ELSE 'r' END)::"char", c.relowner))) x)) AS v
      FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname !~ '^pg_' AND ns.nspname <> 'information_schema'
       -- an extension's own objects come from its install script (a fresh CREATE EXTENSION and an
       -- upgraded one differ, e.g. PostGIS's simple_detail type), not from the data being copied
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.deptype = 'e'
                         AND ((d.classid = 'pg_class'::regclass AND d.objid = c.oid) OR (d.classid = 'pg_type'::regclass AND d.objid = c.reltype)))`)
    relations[r.rel] = r.v
  return { tables, sequences, large_objects: lo.n, ...db, relations }
}

// live: the source was being written during the copy. Tables are still exact (dump and digest
// read one snapshot), but sequences are not transactional: one may move between pg_dump's read
// and ours, so a copy at or below the source is accepted. The cutover copies a stopped source
// and compares sequences exactly.
export function compareDigests(a: Digest, b: Digest, live = false): string[] {
  const diffs: string[] = []
  if (live) {
    a = { ...a, sequences: { ...a.sequences } }
    for (const [k, v] of Object.entries(a.sequences)) {
      const c = b.sequences[k]
      if (c !== undefined && /^\d+$/.test(v) && (c === "unset" || (/^\d+$/.test(c) && BigInt(c) <= BigInt(v)))) a.sequences[k] = c
    }
  }
  const cmp = (what: string, x: Record<string, unknown>, y: Record<string, unknown>) => {
    for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) {
      const l = JSON.stringify(x[k]), r = JSON.stringify(y[k])
      if (l !== r) diffs.push(`${what} ${k}: source ${l ?? "missing"}, copy ${r ?? "missing"}`)
    }
  }
  cmp("table", a.tables, b.tables)
  cmp("sequence", a.sequences, b.sequences)
  cmp("schema", a.schemas, b.schemas)
  cmp("extension", Object.fromEntries(Object.entries(a.extensions).map(([k, v]) => [k, v.schema])), Object.fromEntries(Object.entries(b.extensions).map(([k, v]) => [k, v.schema])))
  if (a.large_objects !== b.large_objects) diffs.push(`large objects: source ${a.large_objects}, copy ${b.large_objects}`)
  if (a.default_privileges.join() !== b.default_privileges.join()) diffs.push(`default privileges: source ${a.default_privileges.join(" ; ")}, copy ${b.default_privileges.join(" ; ")}`)
  cmp("relation", a.relations, b.relations)
  return diffs.length > 50 ? [...diffs.slice(0, 50), `... and ${diffs.length - 50} more`] : diffs
}

async function run(cmd: string[], env: Record<string, string> = {}): Promise<void> {
  const p = Bun.spawn(cmd, { env: { ...process.env, ...env }, stdout: "inherit", stderr: "inherit" })
  if ((await p.exited) !== 0) throw new Error(`${cmd[0].split("/").pop()} exited ${p.exitCode}`)
}

export type CopyArgs = { src: Conn; srcDb: string; dst: Conn; dstDb: string; keepDir: string; live: boolean }

export async function copy({ src, srcDb, dst, dstDb, keepDir, live }: CopyArgs): Promise<{ ok: boolean; report: Record<string, unknown> }> {
  mkdirSync(keepDir, { recursive: true, mode: 0o700 })
  const dumpFile = join(keepDir, `${srcDb}.dump`)
  const target = connect(dst, dstDb)
  const [{ n }] = await target`SELECT count(*)::int AS n FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND ns.nspname !~ '^pg_' AND ns.nspname <> 'information_schema'`
  if (n > 0) { await target.close(); throw new Error(`${dstDb} already has ${n} tables; copy only restores into an empty database`) }
  const srcEnv = src.password ? { PGPASSWORD: src.password } : {}
  const source = connect(src, srcDb)
  const started = Date.now()
  let before: Digest | undefined
  await source.begin(async (tx) => {
    await tx`SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY`
    const [{ snap }] = await tx`SELECT pg_export_snapshot() AS snap`
    const dump = run([`${PG_BIN}/pg_dump`, "-h", src.host, "-p", String(src.port), "-U", src.user, "-d", srcDb, "-Fc", "-Z", "zstd:3", `--snapshot=${snap}`, "-f", dumpFile], srcEnv)
    before = await digest(tx)
    await dump
  })
  await source.close()
  const dumped = Date.now()
  await run([`${PG_BIN}/pg_restore`, "-h", dst.host, "-p", String(dst.port), "-U", dst.user, "-d", dstDb, "--exit-on-error", "-j", "4", dumpFile])
  const restored = Date.now()
  let after: Digest | undefined
  await target.begin(async (tx) => { after = await digest(tx) })
  await target.close()
  const diffs = compareDigests(before!, after!, live)
  const rows = Object.values(before!.tables).reduce((sum, t) => sum + Number(t.split(" ")[0]), 0)
  return {
    ok: diffs.length === 0,
    report: { source: srcDb, copy: dstDb, tables: Object.keys(before!.tables).length, rows, sequences: Object.keys(before!.sequences).length, schemas: Object.keys(before!.schemas).length, dump_seconds: (dumped - started) / 1000, restore_seconds: (restored - dumped) / 1000, dump_file: dumpFile, differences: diffs },
  }
}

// ---------------------------------------------------------------- CLI

export function parseArgs(argv: string[]) {
  const flags: Record<string, string[]> = {}
  const pos: string[] = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (!a.startsWith("--")) { pos.push(a); continue }
    const [k, v] = a.slice(2).split("=", 2)
    const boolish = ["address", "no-schemas", "roles-only", "live"].includes(k)
    const val = v ?? (boolish ? "1" : argv[++i])
    ;(flags[k] ??= []).push(val)
  }
  return { cmd: pos[0], flags, one: (k: string, dflt?: string) => flags[k]?.[0] ?? dflt }
}

function secret(ref: string): string | undefined {
  const p = Bun.spawnSync(["secrets-run", "read", ref], { stdout: "pipe", stderr: "pipe" })
  return p.exitCode === 0 ? p.stdout.toString().replace(/\n$/, "") : undefined
}

async function main() {
  const { cmd, one, flags } = parseArgs(process.argv.slice(2))
  const decl = loadDecl(readFileSync(one("config", CONFIG)!, "utf8"))
  const port = Number(one("port", decl.server.address.port))
  // --socket-dir / --data-dir point the tool at a scratch cluster (the rehearsal's fresh build)
  const su: Conn = { host: one("socket-dir", "/tmp")!, port, user: decl.server.superuser }
  const dataDir = one("data-dir", decl.server.data_dir)!

  if (cmd === "plan" || cmd === "apply") {
    const address = flags.address !== undefined
    const state = await readState(su, dataDir, Object.keys(decl.databases))
    const passwords: Record<string, string | undefined> = {}
    for (const [name, r] of Object.entries(decl.roles)) if (r.password !== "none") passwords[name] = secret(r.password)
    const hbaPath = join(dataDir, "pg_hba.conf")
    const identPath = join(dataDir, "pg_ident.conf")
    const read = (f: string) => (existsSync(f) ? readFileSync(f, "utf8") : "")
    const plan = converge(decl, state, passwords, { address, schemas: flags["no-schemas"] === undefined, rolesOnly: flags["roles-only"] !== undefined, hbaPath, identPath, hbaNow: read(hbaPath), identNow: read(identPath) })
    for (const st of plan.statements) console.log(`${cmd === "plan" ? "would run" : "run"} [${st.db}] ${st.shown ?? st.sql}`)
    for (const f of plan.files) console.log(`${cmd === "plan" ? "would write" : "write"} ${f.path}`)
    for (const dr of plan.drift) console.log(`drift: ${dr}`)
    // a role whose secret is missing would be left without its password: never "in sync", and apply fails
    const missing = plan.drift.filter((d) => d.includes("is not in the secrets cache")).length
    if (cmd === "plan") {
      const pending = plan.statements.length + plan.files.length + missing
      console.log(pending === 0 ? "plan: in sync" : `plan: ${plan.statements.length} statements, ${plan.files.length} files, ${missing} missing secrets`)
      return
    }

    let failed = 0
    const byDb = new Map<string, SQL>()
    try {
      for (const st of plan.statements) {
        if (!byDb.has(st.db)) byDb.set(st.db, connect(su, st.db))
        try { await byDb.get(st.db)!.unsafe(st.sql) } catch (e) { failed++; console.error(`FAILED [${st.db}] ${st.shown ?? st.sql}: ${(e as Error).message}`) }
      }
      const pg = byDb.get("postgres") ?? connect(su, "postgres")
      byDb.set("postgres", pg)
      const old = plan.files.map((f) => ({ path: f.path, content: read(f.path) }))
      for (const f of plan.files) writeFileSync(f.path, f.content, { mode: 0o600 })
      await pg`SELECT pg_reload_conf()`
      if (plan.files.length) {
        const bad = [...(await pg`SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL`), ...(await pg`SELECT line_number, error FROM pg_ident_file_mappings WHERE error IS NOT NULL`)]
        if (bad.length) {
          for (const f of old) writeFileSync(f.path, f.content, { mode: 0o600 })
          await pg`SELECT pg_reload_conf()`
          throw new Error(`hba/ident rejected, previous files restored: ${JSON.stringify(bad)}`)
        }
      }
      const pending = await pg`SELECT name FROM pg_settings WHERE pending_restart`
      if (pending.length) console.log(`restart pending for: ${pending.map((r: { name: string }) => r.name).join(", ")} (brew services restart ${decl.server.service}, or the cutover)`)
    } finally {
      for (const s of byDb.values()) await s.close()
    }
    console.log(failed ? `apply: ${failed} statements failed` : `apply: ${plan.statements.length} statements, ${plan.files.length} files`)
    if (missing) console.error(`apply: ${missing} role passwords are not in the secrets cache (drift above; make secrets-reseal-request)`)
    process.exit(failed || missing ? 1 : 0)
  }

  if (cmd === "snapshot") {
    const host = one("host", su.host)!
    const ref = one("password-ref")
    const c: Conn = { host, port, user: one("user", decl.server.superuser)!, password: ref ? secret(ref) : undefined }
    console.log(JSON.stringify(await snapshot(c, flags.db ?? "all"), null, 2))
    return
  }

  if (cmd === "copy") {
    const db = one("db")
    if (!db) throw new Error("copy needs --db")
    const ref = one("from-password-ref")
    const src: Conn = { host: one("from-host")!, port: Number(one("from-port")), user: one("from-user")!, password: ref ? secret(ref) : undefined }
    if (!src.host || !src.port || !src.user) throw new Error("copy needs --from-host, --from-port and --from-user")
    if (ref && src.password === undefined) throw new Error(`${ref} is not in the secrets cache`)
    const keep = one("keep-dir", join(homedir(), ".local/state/pg-cutover", new Date().toISOString().replace(/[:.]/g, "-")))!
    const { ok, report } = await copy({ src, srcDb: db, dst: su, dstDb: one("as", db)!, keepDir: keep, live: flags.live !== undefined })
    console.log(JSON.stringify(report, null, 2))
    process.exit(ok ? 0 : 1)
  }

  console.error("usage: pg-cluster plan|apply|snapshot|copy (see the header of scripts/pg-cluster.ts)")
  process.exit(2)
}

if (import.meta.main) main().catch((e) => { console.error(`pg-cluster: ${(e as Error).message}`); process.exit(1) })
