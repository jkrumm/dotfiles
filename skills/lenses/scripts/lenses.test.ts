// fallow-ignore-file unused-file -- a bun test: `make lenses-test` runs it, nothing imports it
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CLI = join(import.meta.dir, "lenses.mjs");
const dir = mkdtempSync(join(tmpdir(), "lenses-test-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

function run(...args: string[]) {
  const p = Bun.spawnSync(["node", CLI, "--dir", dir, ...args]);
  return { code: p.exitCode, out: p.stdout.toString(), err: p.stderr.toString() };
}

const CONFIG = {
  title: "Lens test",
  tags: ["subject", "lens-test"],
  date: "2026-01-02",
  index: "wiki/subject/lenses/index",
  parent: "wiki/subject/index|Subject",
  intro: "A test run.",
  groups: [
    ["data", "Data"],
    ["meta", "Adversarial"],
  ],
};

const lens = (n: string, slug: string, group: string, not: string, questions = 6) =>
  [
    `## ${n} | ${slug} | Title of ${n} | ${group}`,
    "role: An expert.",
    "scope: What the lens owns. And a second sentence.",
    `not: ${not}`,
    "prior: none",
    ...Array.from({ length: questions }, (_, i) => `q: Question ${i + 1}?`),
  ].join("\n");

const SECTIONS = [
  "Digest",
  "Questions this lens adds",
  "Findings",
  "Options and verdicts",
  "What the design must guarantee",
  "KPIs and checks",
  "Experiments",
  "Risks and failure modes",
  "Challenges to rulings",
  "Handoffs",
  "Questions for the owner",
  "Sources",
];

/** Turns a stub into a written memo: verdict in the description, status done, every section, enough words. */
function write(file: string, opts: { audit?: boolean; tableRow?: string; drop?: string } = {}) {
  const path = join(dir, file);
  const stub = readFileSync(path, "utf8");
  const head = stub
    .slice(0, stub.indexOf("## Digest"))
    .replace(/^audit: .*\n/m, "")
    .replace(/^description: .*$/m, 'description: "The verdict of this lens."')
    .replace(/^status: .*$/m, opts.audit ? 'status: done\naudit: "2026-01-02: confirmed 5, contradicted 0, not on page 0, unreachable 0"' : "status: done");
  const filler = "word ".repeat(1600);
  const body = SECTIONS.filter((s) => s !== opts.drop)
    .map((s) => `## ${s}\n\n${s === "Findings" ? filler : `One line on ${s}.`}${s === "Handoffs" && opts.tableRow ? `\n\n${opts.tableRow}` : ""}`)
    .join("\n\n");
  writeFileSync(path, `${head}${body}\n`);
}

describe("lenses.mjs", () => {
  test("refuses a directory without lenses.json", () => {
    const r = run("list");
    expect(r.code).toBe(2);
    expect(r.err).toContain("no lenses.json");
  });

  test("stubs: writes one memo per lens and links the neighbours it names", () => {
    writeFileSync(join(dir, "lenses.json"), JSON.stringify(CONFIG));
    writeFileSync(join(dir, "cat.txt"), [lens("L01", "first", "data", "L02 the other half"), lens("L02", "second", "meta", "L01 the first half")].join("\n\n"));
    const r = run("stubs", join(dir, "cat.txt"));
    expect(r.code).toBe(0);
    expect(r.out).toContain("2 stubs written; the catalogue holds 2 lenses and 12 seed questions");
    const stub = readFileSync(join(dir, "l01-first.md"), "utf8");
    expect(stub).toContain('title: "Lens L01 · Title of L01"');
    expect(stub).toContain('description: "Pending. What the lens owns."');
    expect(stub).toContain("  - subject\n  - lens-test\n  - data\n");
    expect(stub).toContain("status: pending");
    expect(stub).toContain("[[l02-second|L02]] the other half");
    expect(stub).toContain("6. Question 6?");
  });

  test("stubs: keeps a memo that exists unless forced", () => {
    expect(run("stubs", join(dir, "cat.txt")).out).toContain("0 stubs written");
  });

  test("stubs: rejects a catalogue with a fault and names it", () => {
    const bad = (text: string) => {
      writeFileSync(join(dir, "bad.txt"), text);
      return run("stubs", join(dir, "bad.txt"));
    };
    expect(bad(lens("L03", "third", "nowhere", "L01 x")).err).toContain('L03 has unknown group "nowhere"');
    expect(bad(lens("L03", "third", "data", "L01 x", 5)).err).toContain("L03 has only 5 seed questions");
    expect(bad(lens("L03", "third", "data", "L77 x")).err).toContain("names L77, which no catalogue or memo defines");
    expect(bad(`${lens("L03", "third", "data", "L01 x")}\n\n${lens("L03", "again", "data", "L01 x")}`).err).toContain("L03 appears twice");
    expect(bad("role: orphan line").code).toBe(2);
  });

  test("index: lists pending lenses by scope, in their groups", () => {
    expect(run("index").out).toContain("index written: 0/2 done");
    const index = readFileSync(join(dir, "index.md"), "utf8");
    expect(index).toContain("Parent: [[wiki/subject/index|Subject]].");
    expect(index).toContain("## 1 · Data\n\n- [[l01-first|L01 · Title of L01]]: (pending) What the lens owns.");
    expect(index).toContain("## 2 · Adversarial");
    expect(index).not.toContain("synthesis-handover");
  });

  test("args: every unwritten lens runs fresh", () => {
    const args = JSON.parse(run("args", "--width", "4").out);
    expect(args).toMatchObject({ dir, total: 2, date: "2026-01-02", width: 4 });
    expect(args.lenses).toEqual([
      { n: "L01", file: "l01-first.md", title: "Title of L01", state: "fresh" },
      { n: "L02", file: "l02-second.md", title: "Title of L02", state: "fresh" },
    ]);
  });

  test("check and args: a written memo without an audit line still owes its audit", () => {
    write("l01-first.md");
    const r = run("check");
    expect(r.code).toBe(1);
    expect(r.out).toContain("L01 l01-first.md: not audited");
    expect(r.out).toContain("L02 l02-second.md: status pending");
    expect(JSON.parse(run("args", "--lens", "L01").out).lenses).toEqual([{ n: "L01", file: "l01-first.md", title: "Title of L01", state: "written" }]);
  });

  test("check: an audited memo with every section passes and leaves the work list", () => {
    write("l01-first.md", { audit: true });
    write("l02-second.md", { audit: true });
    const r = run("check");
    expect(r.out).toContain("2/2 memos without faults");
    expect(r.code).toBe(0);
    expect(JSON.parse(run("args").out).lenses).toEqual([]);
    expect(run("list").out).toContain("L01\tdata\tdone\taudited\t");
  });

  test("check: names a missing section and an unescaped wikilink pipe in a table row", () => {
    write("l01-first.md", { audit: true, drop: "Experiments" });
    write("l02-second.md", { audit: true, tableRow: "| [[l01-first|L01]] | takes the grid |" });
    const r = run("check");
    expect(r.out).toContain("L01 l01-first.md: missing sections: experiments");
    expect(r.out).toContain("L02 l02-second.md: unescaped wikilink pipe in a table row");
    write("l02-second.md", { audit: true, tableRow: "| [[l01-first\\|L01]] | takes the grid |" });
    expect(run("check").out).not.toContain("L02");
  });

  test("section: prints one section of the selected memos; index shows a written memo's verdict", () => {
    const one = run("section", "digest", "--lens", "L02");
    expect(one.out).toBe("# L02 · Title of L02 (meta, l02-second.md)\n\nOne line on Digest.\n\n");
    expect(run("section", "handoffs", "--group", "data").out).toContain("# L01 · Title of L01 (data, l01-first.md)");
    expect(run("section", "nonsense").code).toBe(2);
    run("index");
    expect(readFileSync(join(dir, "index.md"), "utf8")).toContain("- [[l02-second|L02 · Title of L02]]: The verdict of this lens.");
  });
});
