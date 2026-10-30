// Seed a SCRATCH email-gateway store with deterministic fixture mail (never the production store).
//
//   DATA_DIR=<scratch>/email/data <dummy env> bun run seed_email_fixture.ts <truth.json>
//
// Uses the repo's own store modules (openMailDatabase, createMessagesRepo, createAccountsRepo) so
// the FTS index, locations and classifications are exactly what the service writes. The ground
// truth the graders check (counts, keys, amounts) is written to <truth.json>.

import { writeFileSync } from "node:fs";
import { join } from "node:path";

const REPO = process.env.EMAIL_GATEWAY_REPO ?? `${process.env.HOME}/SourceRoot/email-gateway`;
const { openMailDatabase } = await import(join(REPO, "src/db/mail-client.ts"));
const { createAccountsRepo } = await import(join(REPO, "src/db/accounts.ts"));
const { createMessagesRepo } = await import(join(REPO, "src/db/messages.ts"));

// Fixture addresses are written with ${AT} so the public-repo redaction check does not mistake them for real mail.
const AT = "@";
const out = process.argv[2];
if (!out || !process.env.DATA_DIR) throw new Error("usage: DATA_DIR=<dir> bun run seed_email_fixture.ts <truth.json>");

const db = openMailDatabase(join(process.env.DATA_DIR, "mail.sqlite"));
const accounts = createAccountsRepo(db);
const messages = createMessagesRepo(db);

const GMAIL = `gmail:fixture.owner${AT}example.com`;
const PROTON = `proton:fixture.owner${AT}example.org`;
accounts.upsertAccount({ id: GMAIL, provider: "gmail", address: `fixture.owner${AT}example.com` });
accounts.upsertAccount({ id: PROTON, provider: "proton", address: `fixture.owner${AT}example.org` });

// Deterministic PRNG (mulberry32) so every seeding produces the same shape.
let s = 20261022;
const rnd = () => ((s = (s + 0x6d2b79f5) | 0), (((t) => ((t ^ (t >>> 15)) * (1 | t)) ^ ((t ^ (t >>> 7)) * (61 | t)))(s) >>> 0) / 4294967296);
const pick = <T,>(a: T[]) => a[Math.floor(rnd() * a.length)]!;

const now = Date.now();
const minutesAgo = (m: number) => new Date(now - m * 60_000).toISOString();

type Seed = { key: string; account: string; subject: string; from: string; category: string; action: boolean; seen: boolean; minutes: number; body: string; summary: string };
const seeds: Seed[] = [];
const filler = [
  ["newsletter", "Weekly digest: build tools", `digest${AT}news.example`, "A roundup of build tool releases."],
  ["notification", "Your CI run finished", `ci${AT}builds.example`, "Pipeline finished without failures."],
  ["social", "New follower on the forum", `noreply${AT}forum.example`, "Someone followed your profile."],
  ["receipt", "Receipt for your coffee order", `orders${AT}beans.example`, "Order paid, nothing to do."],
  ["travel", "Your train departs tomorrow", `tickets${AT}rail.example`, "Ticket confirmation, no action."],
];
for (let i = 0; i < 52; i++) {
  const [category, subject, from, summary] = pick(filler) as [string, string, string, string];
  seeds.push({ key: `fx-${String(i).padStart(3, "0")}`, account: rnd() < 0.6 ? GMAIL : PROTON, subject: `${subject} #${i}`, from, category, action: false, seen: rnd() < 0.55, minutes: 60 + Math.floor(rnd() * 60 * 24 * 9), body: `${summary} (fixture ${i})`, summary });
}
// Needles with known answers.
const needles: Seed[] = [
  { key: "fx-inv-acme", account: GMAIL, subject: "Invoice INV-2026-0417 from Acme Cloud GmbH", from: `billing${AT}acme-cloud.example`, category: "invoice", action: true, seen: false, minutes: 300, body: "Dear customer, invoice INV-2026-0417 is attached.\nAmount due: EUR 1,284.50\nDue date: 2026-11-07\nPay by bank transfer to the account on the invoice.", summary: "Acme Cloud invoice INV-2026-0417, EUR 1,284.50 due 2026-11-07." },
  { key: "fx-act-1", account: GMAIL, subject: "Contract renewal: signature needed by Friday", from: `legal${AT}partner.example`, category: "work", action: true, seen: false, minutes: 20, body: "Please sign the renewal by Friday.", summary: "Contract renewal needs a signature by Friday." },
  { key: "fx-act-2", account: PROTON, subject: "Tax advisor: documents missing", from: `office${AT}tax.example`, category: "work", action: true, seen: false, minutes: 190, body: "Two documents are missing.", summary: "Tax advisor needs two documents." },
  { key: "fx-act-3", account: GMAIL, subject: "Domain renewal expires in 6 days", from: `support${AT}registrar.example`, category: "notification", action: true, seen: true, minutes: 700, body: "Renew your domain.", summary: "Domain renewal in 6 days." },
  { key: "fx-act-4", account: PROTON, subject: "Dentist appointment: please confirm", from: `frontdesk${AT}clinic.example`, category: "personal", action: true, seen: false, minutes: 1500, body: "Please confirm Thursday 10:00.", summary: "Confirm dentist appointment." },
  { key: "fx-act-5", account: GMAIL, subject: "Reviewer feedback on your pull request", from: `notify${AT}forge.example`, category: "work", action: true, seen: true, minutes: 2600, body: "Two comments need replies.", summary: "PR needs replies." },
  { key: "fx-act-6", account: PROTON, subject: "Insurance renewal quote", from: `quotes${AT}insure.example`, category: "personal", action: true, seen: false, minutes: 4100, body: "Quote attached; decide by month end.", summary: "Insurance quote, decide by month end." },
];
seeds.push(...needles);

let unreadGmailInbox = 0;
let needsAction = 0;
for (const x of seeds) {
  const date = minutesAgo(x.minutes);
  messages.upsertMessage({
    key: x.key, account: x.account, direction: "inbound", fromAddress: x.from, toAddresses: [x.account.split(":")[1]!],
    cc: null, bcc: null, replyTo: null, subject: x.subject, date, size: 2048, hasAttachments: false,
    threadKey: `thr-${x.key}`, flags: x.seen ? ["\\Seen"] : [],
  });
  messages.upsertLocation(x.key, { mailbox: "INBOX", uidValidity: "1", uid: seeds.indexOf(x) + 1, providerRef: { mailbox: "INBOX", uid: seeds.indexOf(x) + 1 }, lastSeenAt: date });
  messages.saveEnrichment(x.key, { category: x.category, priority: x.action ? "high" : "low", actionRequired: x.action, summary: x.summary, suggestedAction: x.action ? "reply" : null, language: "en", facts: null, model: "fixture", error: null });
  messages.saveBody(x.key, { html: null, text: x.body });
  if (x.account === GMAIL && !x.seen) unreadGmailInbox++;
  if (x.action) needsAction++;
}

const newest = needles.filter((n) => n.action).sort((a, b) => a.minutes - b.minutes)[0]!;
const truth = {
  seeded_messages: seeds.length,
  needs_action_count: needsAction,
  newest_needs_action_subject: newest.subject,
  newest_needs_action_key: newest.key,
  invoice_key: "fx-inv-acme",
  invoice_category: "invoice",
  invoice_amount: "1,284.50",
  invoice_due: "2026-11-07",
  unread_gmail_total: unreadGmailInbox,
  accounts: [GMAIL, PROTON],
};
writeFileSync(out, JSON.stringify(truth, null, 1) + "\n");
console.log(JSON.stringify(truth));
