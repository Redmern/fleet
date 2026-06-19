# Browser-testing a web app you built (`fleet browser`)

A fleet **worker** can functionally test the web app it itself started by driving
the **system Chromium** with Playwright. No bundled-browser download: the vendored
`playwright-core` (in `fleet/lib/`) points at `/usr/bin/chromium`.

Two modes, one flag apart:

- **headless (default)** — fast, robust, screenshots always paint. The right mode
  for an agent's automated test loop.
- **`--watch`** — a Hyprland-tiled, genuinely **on-screen** headed Chromium the
  human also watches, driven over CDP. A headed Wayland surface must be visible to
  screenshot (an occluded surface stalls capture).

## Worker recipe (the universal, harness-agnostic path)

1. **Start your dev server**, then advertise its port (mirrors the `.fleet/ready`
   marker convention):

   ```sh
   fleet devport 5173        # writes <worktree>/.fleet/devport
   # (or just: echo 5173 > .fleet/devport)
   ```

2. **Run the browser test** from inside your worktree:

   ```sh
   fleet browser             # reads .fleet/devport → http://localhost:5173
   fleet browser 5173        # bare port override
   fleet browser http://localhost:5173/page   # full-URL override
   ```

3. **Read the JSON** it prints to stdout. Shape:

   ```json
   {
     "url": "...", "ok": true, "title": "...", "dom": "<body innerText, truncated>",
     "errs": ["console.error + pageerror + failed-resource messages"],
     "netReqs": ["finished request URLs"], "netFails": ["failed request URLs"],
     "asserts": { "...": "whatever your hook returned" },
     "hookError": "", "screenshot": "/abs/path/.fleet/shots/shot.png",
     "shotErr": "", "navErr": ""
   }
   ```

   Check `errs` for console errors, `asserts` for your own assertions, `ok`/`navErr`
   for whether the page loaded.

4. **`Read` the screenshot** at the printed `screenshot` path — that's the agent's
   eyes on the rendered, post-interaction page.

## Scripting clicks / assertions (pluggable hook)

Drop a `<worktree>/.fleet/hook.js` exporting an async function `(page) => object`.
`fleet browser` runs it after navigation; whatever it returns lands in the JSON's
`asserts`. `page` is a Playwright [`Page`](https://playwright.dev/docs/api/class-page).

```js
// .fleet/hook.js — exercise the UI, return assertions
module.exports = async (page) => {
  await page.click('#submit');
  await page.fill('#name', 'fleet');
  return {
    heading: await page.textContent('h1'),
    result:  await page.textContent('#out'),     // proves the click did something
    apiVal:  await page.getAttribute('#hdr', 'data-api-val'),
  };
};
```

## Watch it live (headed)

```sh
fleet browser --watch        # launches a visible tiled Chromium, drives it over CDP
```

The window is left open for you after the run; the debug port (default 9222) is
freed on `fleet reap`, or close it manually:

```sh
fuser -k 9222/tcp
```

## Opt-in: inline screenshots via browser MCP (claude workers only)

The file→`Read` path above is the **universal default** and works for every
harness. A **claude** worker that wants screenshots returned *inline in the tool
result* (no write-then-`Read`) can opt into a browser MCP server — add to the
worktree's `.mcp.json`:

```json
{ "mcpServers": { "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] } } }
```

(or `chrome-devtools-mcp`). This is claude-specific and needs per-worker config;
the MCP server still launches its own browser, so it's a convenience, not the
baseline. The `fleet browser` snippet stays the recommended cross-harness path.

## One-time setup

`./install.sh` vendors the driver deps automatically (`cd lib && npm i`,
`playwright-core` only — no browser download). On a fresh clone without running
the installer:

```sh
( cd fleet/lib && npm i )
```

`fleet/lib/node_modules/` and every `.fleet/shots/` are gitignored (disposable).
