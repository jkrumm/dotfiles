#!/usr/bin/env bun
// A stand-in for Chrome's DevTools endpoint, for scripts/shared-chrome.test.ts only. Takes Chrome's own
// --remote-debugging-port flag, answers /json/version and the four Target.* calls the supervisor makes, and
// lets the test edit the world over POST /_fake/{context,page,title}.
const port = Number(process.argv.find((a) => a.startsWith("--remote-debugging-port="))?.split("=")[1])
// A loaded machine starts Chrome slowly: FAKE_CHROME_DELAY_MS holds the DevTools port closed that long.
await Bun.sleep(Number(process.env.FAKE_CHROME_DELAY_MS ?? 0))
const contexts = new Set<string>()
const pages = new Map<string, { targetId: string; type: string; url: string; title: string; browserContextId: string }>()
pages.set("p0", { targetId: "p0", type: "page", url: "about:blank", title: "", browserContextId: "default" })

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(req, srv) {
    const url = new URL(req.url)
    if (url.pathname === "/json/version") {
      return Response.json({ Browser: "Fake/1", webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/fake` })
    }
    if (url.pathname === "/devtools/browser/fake") return srv.upgrade(req) ? undefined : new Response("no", { status: 400 })
    if (url.pathname === "/_fake/state") return Response.json({ contexts: [...contexts], pages: [...pages.values()] })
    const body = req.method === "POST" ? ((await req.json()) as Record<string, string>) : {}
    if (url.pathname === "/_fake/context") contexts.add(body.id!)
    if (url.pathname === "/_fake/page") {
      pages.set(body.id!, { targetId: body.id!, type: "page", url: body.url ?? "https://example.com/", title: "", browserContextId: body.context! })
    }
    if (url.pathname === "/_fake/title") pages.get(body.id!)!.title = body.title!
    return Response.json({ ok: true })
  },
  websocket: {
    message(ws, raw) {
      const { id, method, params } = JSON.parse(String(raw))
      let result: unknown = {}
      if (method === "Target.getBrowserContexts") result = { browserContextIds: [...contexts], defaultBrowserContextId: "default" }
      if (method === "Target.getTargets") result = { targetInfos: [...pages.values()] }
      if (method === "Target.disposeBrowserContext") {
        contexts.delete(params.browserContextId)
        for (const [k, p] of pages) if (p.browserContextId === params.browserContextId) pages.delete(k)
      }
      if (method === "Target.closeTarget") pages.delete(params.targetId)
      ws.send(JSON.stringify({ id, result }))
    },
  },
})
process.on("SIGTERM", () => {
  server.stop(true)
  process.exit(0)
})
