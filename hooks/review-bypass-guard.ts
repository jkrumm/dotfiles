#!/usr/bin/env bun

/**
 * PreToolUse hook: a factory lead cannot bypass a required review.
 *
 * Incident 2026-11-05: an Issue lead was told "do not merge with --admin; leave
 * open for a reviewer", wrote "Owner approved the admin merge" with no such
 * approval in its transcript, and merged a work repo's PR past its required
 * review. A sentence in an answer cannot be the only guard for bypassing
 * another team's rule, so the bypass itself is denied.
 *
 * Active only when FACTORY_SESSION is set (`rd work` / `rd issue` spawns). The
 * owner's own sessions are untouched; the bypass stays the owner's to do by hand.
 *
 * Denied (command position only — quoted text is data, see docker-makefile.ts):
 *   - `gh pr merge … --admin`;
 *   - `gh api` on a merge endpoint (`…/pulls/<n>/merge`, `…/merges`) with any
 *     method but GET;
 *   - `gh api` that writes rulesets or branch protection (`…/rulesets`,
 *     `…/branches/<b>/protection`) — any method but GET;
 *   - `gh api graphql` carrying a merge / ruleset / branch-protection mutation,
 *     or a query the hook cannot read (`--input`, `-f query=@file`, `$VAR` /
 *     `$(…)` in the query);
 *   - `gh api` with a non-GET method on an endpoint a variable completes
 *     (`repos/o/r/$S`), unless its literal text names an unrelated resource
 *     (`…/issues/$N/comments`) or a single `pulls/$N` id slot.
 *
 * The tokenizer drops quote types, so `$name` in a single-quoted GraphQL query
 * (`query($o:String!)`) reads as a shell variable and is denied too.
 *
 * Allowed: `gh pr merge --squash|--rebase|--merge|--auto`, `gh api` reads of the
 * same endpoints, and every word above inside quotes (a commit message, a grep).
 *
 * Not covered (same hazard class): `curl`/`wget` straight at api.github.com,
 * `gh alias set` wrapping `--admin`, and other forges' CLIs.
 */

import { collect, type Invocation } from "./broad-kill-guard.ts";

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
}

const OWNER =
  "This bypasses a required review and is the owner's to do by hand, not a factory lead's. " +
  "Leave the PR open for its reviewer, or `factory issue ask` the owner.";

// ── gh pr merge ──────────────────────────────────────────────────────────────

/** `--admin` or `--admin=true`; `--admin=false` is a no-op. */
const isAdminFlag = (a: string): boolean => a === "--admin" || (a.startsWith("--admin=") && a.slice(8) !== "false");

// ── gh api ───────────────────────────────────────────────────────────────────

const API_VALUE_FLAGS = new Set([
  "-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header", "--input",
  "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview",
]);
const API_BODY_FLAGS = new Set(["-f", "--raw-field", "-F", "--field", "--input"]);

interface ApiCall {
  endpoint: string;
  method: string;
  /** Values of -f/-F/--field/--raw-field (`key=value`) and `--input` paths. */
  fields: string[];
  hasInput: boolean;
}

function parseApi(args: string[]): ApiCall {
  let endpoint = "";
  let method: string | undefined;
  const fields: string[] = [];
  let hasInput = false;

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const eq = a.startsWith("--") ? a.indexOf("=") : -1;
    const flag = eq === -1 ? a : a.slice(0, eq);
    if (!a.startsWith("-") || a === "-") {
      if (!endpoint) endpoint = a;
      continue;
    }
    // `-XPOST`, `-fkey=v`: attached short-flag value.
    const short = !a.startsWith("--") && a.length > 2 ? a.slice(0, 2) : undefined;
    const name = short && API_VALUE_FLAGS.has(short) ? short : flag;
    if (!API_VALUE_FLAGS.has(name)) continue;
    const value = eq !== -1 ? a.slice(eq + 1) : short && name === short ? a.slice(2) : (args[++i] ?? "");
    if (name === "-X" || name === "--method") method = value.toUpperCase();
    if (name === "--input") hasInput = true;
    if (API_BODY_FLAGS.has(name)) fields.push(value);
  }
  // gh sends POST as soon as a body or field is given and no method is.
  return { endpoint, method: method ?? (fields.length ? "POST" : "GET"), fields, hasInput };
}

/** `https://api.github.com/repos/o/r/rulesets?x=1` → `repos/o/r/rulesets`. */
function normalizeEndpoint(raw: string): string {
  return raw
    .replace(/^https?:\/\/[^/]+\//, "")
    .replace(/[?#].*$/, "")
    .replace(/^\/+|\/+$/g, "");
}

const MERGE_ENDPOINT = /(?:^|\/)(?:pulls\/[^/]+\/merge|merges)$/;
const RULE_ENDPOINT = /(?:^|\/)rulesets(?:\/|$)|\/branches\/.+\/protection(?:\/|$)|\/protected_branches?(?:\/|$)/;
const GRAPHQL_MUTATION =
  /\b(?:mergePullRequest|mergeBranch|(?:create|update|delete)(?:RepositoryRuleset|BranchProtectionRule))\b/;

/**
 * A value only the shell can resolve: `$VAR`, `${VAR}`, a backtick, or the NUL
 * the tokenizer leaves for a `$(…)` substitution.
 */
const UNRESOLVED = /\$|`|\0/;

/**
 * A non-GET call whose endpoint holds a variable is allowed only when its literal
 * text names an unrelated resource (`repos/$REPO/issues/$N/comments`) or ends in
 * a single id slot (`pulls/$N`). A variable can carry the whole tail
 * (`S=pulls/12/merge; gh api -X PUT repos/o/r/$S`), so anything else is denied.
 */
const SAFE_WITH_VARIABLE =
  /(?:^|\/)(?:issues|labels|releases|statuses|check-runs|deployments|dispatches|contents|git|actions|comments|hooks)(?:\/|$)|(?:^|\/)pulls\/x$/;

function apiViolation(args: string[]): string | null {
  const call = parseApi(args);
  const hasVariable = UNRESOLVED.test(call.endpoint);
  // `repos/o/r/pulls/$N/merge` still shows its shape with the variable blanked.
  const endpoint = normalizeEndpoint(call.endpoint.replace(/\$\{?\w+\}?|\0/g, "x"));

  if (endpoint === "graphql") {
    // A query read from a file, stdin or the shell cannot be inspected.
    if (call.hasInput || call.fields.some((f) => /^query=@/.test(f) || (/^query=/.test(f) && UNRESOLVED.test(f)))) {
      return `\`gh api graphql\` with a query from a file, stdin or a shell expansion cannot be inspected for a merge or ruleset mutation. ${OWNER}`;
    }
    if (call.fields.some((f) => GRAPHQL_MUTATION.test(f))) {
      return `A GraphQL merge / ruleset / branch-protection mutation. ${OWNER}`;
    }
    return null;
  }

  if (call.method === "GET") return null;
  if (MERGE_ENDPOINT.test(endpoint)) return `\`gh api\` ${call.method} on a merge endpoint (${endpoint}). ${OWNER}`;
  if (RULE_ENDPOINT.test(endpoint)) {
    return `\`gh api\` ${call.method} on rulesets or branch protection (${endpoint}). ${OWNER}`;
  }
  if (hasVariable && !SAFE_WITH_VARIABLE.test(endpoint)) {
    return `\`gh api\` ${call.method} on an endpoint the shell completes (${call.endpoint}); it cannot be checked for a merge or ruleset write. ${OWNER}`;
  }
  return null;
}

// ── Policy ───────────────────────────────────────────────────────────────────

/** Leading words of a gh command, skipping `-R <repo>` / `--repo <repo>` (cobra allows them before the verb). */
function subcommands(args: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length && out.length < 2; i++) {
    const a = args[i];
    if (a === "-R" || a === "--repo") i++;
    else if (!a.startsWith("-")) out.push(a);
  }
  return out;
}

/** Why this command must not run in a factory session, or null when it may. */
export function findViolation(command: string): string | null {
  // gh's own `{owner}` / `{repo}` / `{branch}` endpoint placeholders: the tokenizer reads braces as command groups.
  const flattened = command.replace(/\{(owner|repo|branch)\}/g, "$1");
  for (const inv of collect(flattened) as Invocation[]) {
    if (inv.name !== "gh") continue;
    const positionals = subcommands(inv.args);

    if (positionals[0] === "pr" && positionals[1] === "merge" && inv.args.some(isAdminFlag)) {
      return `\`gh pr merge --admin\` merges past required reviews and checks. ${OWNER}`;
    }
    if (positionals[0] === "api") {
      const at = inv.args.indexOf("api");
      const violation = apiViolation(inv.args.slice(at + 1));
      if (violation) return violation;
    }
  }
  return null;
}

function deny(reason: string): never {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    }),
  );
  process.exit(0);
}

// ── Main ─────────────────────────────────────────────────────────────────────

if (import.meta.main) {
  if (!process.env.FACTORY_SESSION) process.exit(0);
  const input: HookInput = JSON.parse(await Bun.stdin.text());
  if (input.tool_name !== "Bash") process.exit(0);

  const violation = findViolation((input.tool_input?.command ?? "").trim());
  if (violation) deny(violation);
}
