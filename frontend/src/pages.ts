import { html } from "hono/html";

const SHELL_HEAD = html`
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="dark" />
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    body {
      font-family:
        ui-sans-serif,
        system-ui,
        -apple-system,
        Segoe UI,
        sans-serif;
      background:
        radial-gradient(
          1200px 800px at 80% -10%,
          rgba(99, 102, 241, 0.15),
          transparent 60%
        ),
        radial-gradient(
          900px 700px at -10% 110%,
          rgba(16, 185, 129, 0.1),
          transparent 60%
        ),
        #0b0e14;
      color: #e6e8eb;
    }
    .glass {
      background: rgba(20, 25, 35, 0.6);
      backdrop-filter: blur(8px);
      border: 1px solid rgba(255, 255, 255, 0.06);
    }
    code,
    pre,
    .mono {
      font-family:
        ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono",
        monospace;
    }
    input,
    select,
    textarea,
    button {
      font: inherit;
    }
    .btn {
      background: #4f46e5;
      color: white;
      padding: 0.55rem 1rem;
      border-radius: 0.5rem;
      font-weight: 500;
      transition: background 0.15s ease;
    }
    .btn:hover {
      background: #4338ca;
    }
    .btn:disabled {
      background: #312e81;
      cursor: not-allowed;
    }
    .btn-ghost {
      background: transparent;
      border: 1px solid rgba(255, 255, 255, 0.12);
      color: #e6e8eb;
      padding: 0.55rem 1rem;
      border-radius: 0.5rem;
    }
    .btn-ghost:hover {
      background: rgba(255, 255, 255, 0.04);
    }
    .field {
      background: rgba(0, 0, 0, 0.25);
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 0.5rem;
      padding: 0.55rem 0.75rem;
      color: #e6e8eb;
      width: 100%;
    }
    .field:focus {
      outline: none;
      border-color: #6366f1;
      box-shadow: 0 0 0 2px rgba(99, 102, 241, 0.25);
    }
    .label {
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: #9aa3af;
      margin-bottom: 0.35rem;
      display: block;
    }
    .pill {
      font-size: 0.7rem;
      padding: 0.15rem 0.55rem;
      border-radius: 999px;
      border: 1px solid rgba(255, 255, 255, 0.1);
    }
    .pill-ok {
      background: rgba(16, 185, 129, 0.12);
      color: #34d399;
      border-color: rgba(16, 185, 129, 0.3);
    }
    .pill-bad {
      background: rgba(239, 68, 68, 0.12);
      color: #f87171;
      border-color: rgba(239, 68, 68, 0.3);
    }
    .pill-warn {
      background: rgba(234, 179, 8, 0.12);
      color: #facc15;
      border-color: rgba(234, 179, 8, 0.3);
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.875rem;
    }
    th,
    td {
      text-align: left;
      padding: 0.55rem 0.75rem;
      border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    }
    th {
      color: #9aa3af;
      font-weight: 500;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.06em;
    }
    .modal-backdrop {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.6);
      display: none;
      align-items: center;
      justify-content: center;
      z-index: 50;
    }
    .modal-backdrop.show {
      display: flex;
    }
  </style>
`;

export function loginPage(error?: string) {
  return html`<!doctype html>
    <html lang="en">
      <head>
        ${SHELL_HEAD}
        <title>Premium LLM Gateway · Sign in</title>
      </head>
      <body class="min-h-screen flex items-center justify-center px-4">
        <main class="glass rounded-2xl p-8 w-full max-w-sm">
          <h1 class="text-2xl font-semibold mb-1">Premium LLM Gateway</h1>
          <p class="text-sm text-zinc-400 mb-6">Admin sign-in</p>
          ${error
            ? html`<div
                class="mb-4 text-sm text-red-300 bg-red-500/10 border border-red-500/30 rounded-md px-3 py-2"
              >
                ${error}
              </div>`
            : ""}
          <form method="post" action="/login" class="space-y-4">
            <div>
              <label class="label" for="password">Admin password</label>
              <input
                class="field"
                type="password"
                id="password"
                name="password"
                required
                autofocus
                autocomplete="current-password"
              />
            </div>
            <button class="btn w-full" type="submit">Sign in</button>
          </form>
          <p class="text-xs text-zinc-500 mt-6">
            This password mints LiteLLM virtual keys. Treat it like a master
            credential.
          </p>
        </main>
      </body>
    </html>`;
}

export function dashboardPage(opts: { litellmUrl: string; baseHost: string }) {
  return html`<!doctype html>
    <html lang="en">
      <head>
        ${SHELL_HEAD}
        <title>Premium LLM Gateway · Dashboard</title>
      </head>
      <body class="min-h-screen">
        <header
          class="glass border-b border-white/5 px-6 py-4 flex items-center justify-between"
        >
          <div class="flex items-center gap-3">
            <div
              class="w-8 h-8 rounded-md bg-gradient-to-br from-indigo-500 to-emerald-400 flex items-center justify-center font-semibold"
            >
              U
            </div>
            <div>
              <div class="font-semibold">Premium LLM Gateway</div>
              <div class="text-xs text-zinc-400 mono" id="endpoint-line">
                ${opts.baseHost}/v1
              </div>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <span class="pill" id="health-pill">checking…</span>
            <form method="post" action="/logout">
              <button class="btn-ghost text-sm" type="submit">Sign out</button>
            </form>
          </div>
        </header>

        <main class="p-6 max-w-6xl mx-auto space-y-6">
          <section class="glass rounded-2xl p-5">
            <h2 class="font-semibold mb-1">For Cursor / IDE clients</h2>
            <p class="text-sm text-zinc-400 mb-3">
              Hand the user these three values. The gateway picks the actual
              backend based on the active routing mode on RunPod.
            </p>
            <div class="grid sm:grid-cols-3 gap-3 text-sm">
              <div class="bg-black/30 rounded-lg p-3">
                <div class="label">Base URL</div>
                <code id="copy-base" class="break-all text-emerald-300"
                  >${opts.baseHost}/v1</code
                >
              </div>
              <div class="bg-black/30 rounded-lg p-3">
                <div class="label">Model</div>
                <code class="text-emerald-300">dev-auto</code>
              </div>
              <div class="bg-black/30 rounded-lg p-3">
                <div class="label">API key</div>
                <span class="text-zinc-400"
                  >Generate one below ↓</span
                >
              </div>
            </div>
          </section>

          <div class="grid lg:grid-cols-2 gap-6">
            <section class="glass rounded-2xl p-5">
              <h2 class="font-semibold mb-4">Generate virtual key</h2>
              <form id="keyform" class="space-y-3">
                <div class="grid grid-cols-2 gap-3">
                  <div>
                    <label class="label" for="user_id">User ID</label>
                    <input
                      class="field"
                      id="user_id"
                      name="user_id"
                      value="jonathan"
                      required
                    />
                  </div>
                  <div>
                    <label class="label" for="test_type">Test type</label>
                    <select class="field" id="test_type" name="test_type">
                      <option value="premium_user_full_weight" selected>
                        premium_user_full_weight (Mode A)
                      </option>
                      <option value="balanced">balanced (Mode B)</option>
                      <option value="aggressive_margin">
                        aggressive_margin (Mode C)
                      </option>
                      <option value="benchmark">benchmark</option>
                    </select>
                  </div>
                </div>
                <div class="grid grid-cols-2 gap-3">
                  <div>
                    <label class="label" for="duration">Duration</label>
                    <input
                      class="field"
                      id="duration"
                      name="duration"
                      value="30d"
                      placeholder="e.g. 30d, 14d, 24h"
                    />
                  </div>
                  <div>
                    <label class="label" for="max_budget"
                      >Max budget (USD)</label
                    >
                    <input
                      class="field"
                      id="max_budget"
                      name="max_budget"
                      type="number"
                      step="1"
                      value="2000"
                    />
                  </div>
                </div>
                <div>
                  <label class="label">Allowed models</label>
                  <div class="grid grid-cols-2 gap-2 text-sm">
                    <label class="flex items-center gap-2"
                      ><input
                        type="checkbox"
                        name="model"
                        value="dev-auto"
                        checked
                      />
                      dev-auto</label
                    >
                    <label class="flex items-center gap-2"
                      ><input
                        type="checkbox"
                        name="model"
                        value="mimo-pro"
                        checked
                      />
                      mimo-pro</label
                    >
                    <label class="flex items-center gap-2"
                      ><input
                        type="checkbox"
                        name="model"
                        value="deepseek-v4-pro"
                        checked
                      />
                      deepseek-v4-pro</label
                    >
                    <label class="flex items-center gap-2"
                      ><input
                        type="checkbox"
                        name="model"
                        value="deepseek-v4-flash"
                        checked
                      />
                      deepseek-v4-flash</label
                    >
                    <label class="flex items-center gap-2"
                      ><input
                        type="checkbox"
                        name="model"
                        value="claude-benchmark"
                        checked
                      />
                      claude-benchmark</label
                    >
                  </div>
                </div>
                <button class="btn w-full" type="submit" id="keyform-submit">
                  Generate key
                </button>
                <p class="text-xs text-zinc-500">
                  Returned keys are shown once, on the next screen. Store them
                  immediately.
                </p>
              </form>
            </section>

            <section class="glass rounded-2xl p-5">
              <div class="flex items-center justify-between mb-4">
                <h2 class="font-semibold">Existing keys &amp; spend</h2>
                <button id="refresh-keys" class="btn-ghost text-sm">
                  Refresh
                </button>
              </div>
              <div
                id="keys-table-wrap"
                class="overflow-x-auto"
                style="min-height: 6rem"
              >
                <div class="text-zinc-500 text-sm py-6 text-center">
                  loading…
                </div>
              </div>
            </section>
          </div>

          <section class="glass rounded-2xl p-5">
            <h2 class="font-semibold mb-3">Smoke test</h2>
            <p class="text-sm text-zinc-400 mb-3">
              Sends a real chat completion through this Railway endpoint into
              LiteLLM. Use any virtual key.
            </p>
            <div class="grid sm:grid-cols-3 gap-3">
              <input
                class="field sm:col-span-2"
                id="smoke-key"
                placeholder="sk-…"
                autocomplete="off"
              />
              <button class="btn" id="smoke-go">Send "ping"</button>
            </div>
            <pre
              id="smoke-out"
              class="mt-3 text-xs bg-black/40 border border-white/5 rounded-lg p-3 whitespace-pre-wrap"
            ></pre>
          </section>
        </main>

        <!-- modal: show generated key once -->
        <div class="modal-backdrop" id="key-modal">
          <div class="glass rounded-2xl p-6 max-w-lg w-[90%]">
            <h3 class="text-lg font-semibold mb-2">New key generated</h3>
            <p class="text-sm text-zinc-400 mb-3">
              This is the only time you will see the full key. Copy it now.
            </p>
            <pre
              id="key-modal-value"
              class="bg-black/40 border border-white/5 rounded-lg p-3 break-all text-emerald-300 text-sm"
            ></pre>
            <div class="flex gap-2 mt-4">
              <button class="btn" id="copy-key">Copy</button>
              <button class="btn-ghost" id="close-modal">Done</button>
            </div>
          </div>
        </div>

        <script>
          const $ = (id) => document.getElementById(id);

          async function checkHealth() {
            try {
              const r = await fetch("/api/health");
              const j = await r.json();
              const pill = $("health-pill");
              if (j.ok) {
                pill.textContent = "online";
                pill.className = "pill pill-ok";
              } else {
                pill.textContent = "offline";
                pill.className = "pill pill-bad";
              }
            } catch (e) {
              const pill = $("health-pill");
              pill.textContent = "unreachable";
              pill.className = "pill pill-bad";
            }
          }

          async function loadKeys() {
            const wrap = $("keys-table-wrap");
            wrap.innerHTML =
              '<div class="text-zinc-500 text-sm py-6 text-center">loading…</div>';
            try {
              const r = await fetch("/api/keys");
              const j = await r.json();
              const rows = (j.keys || j.data || j || [])
                .slice()
                .sort((a, b) => (b.spend || 0) - (a.spend || 0));
              if (!rows.length) {
                wrap.innerHTML =
                  '<div class="text-zinc-500 text-sm py-6 text-center">no keys yet</div>';
                return;
              }
              const fmt = (n) => "$" + (Number(n) || 0).toFixed(2);
              const head =
                "<table><thead><tr><th>Key</th><th>User</th><th>Spend</th><th>Budget</th><th>Models</th></tr></thead><tbody>";
              const body = rows
                .map((k) => {
                  const meta = k.metadata || {};
                  const user =
                    meta.user_id || k.user_id || k.user || "—";
                  const tag = (k.token || k.api_key || "").slice(-6);
                  const models = (k.models || []).join(", ") || "*";
                  const budget = k.max_budget
                    ? fmt(k.max_budget)
                    : "—";
                  return (
                    "<tr><td class='mono text-emerald-300'>…" +
                    escapeHtml(tag) +
                    "</td><td>" +
                    escapeHtml(user) +
                    "</td><td class='mono'>" +
                    fmt(k.spend) +
                    "</td><td class='mono text-zinc-400'>" +
                    budget +
                    "</td><td class='text-zinc-400 text-xs'>" +
                    escapeHtml(models) +
                    "</td></tr>"
                  );
                })
                .join("");
              wrap.innerHTML = head + body + "</tbody></table>";
            } catch (e) {
              wrap.innerHTML =
                "<div class='text-red-300 text-sm py-6 text-center'>error: " +
                escapeHtml(String(e)) +
                "</div>";
            }
          }

          function escapeHtml(s) {
            return String(s).replace(
              /[&<>'"]/g,
              (c) =>
                ({
                  "&": "&amp;",
                  "<": "&lt;",
                  ">": "&gt;",
                  "'": "&#39;",
                  '"': "&quot;",
                })[c],
            );
          }

          $("keyform").addEventListener("submit", async (ev) => {
            ev.preventDefault();
            const btn = $("keyform-submit");
            btn.disabled = true;
            btn.textContent = "Generating…";
            const fd = new FormData(ev.target);
            const models = fd.getAll("model");
            const payload = {
              models,
              duration: fd.get("duration") || undefined,
              max_budget: Number(fd.get("max_budget")) || undefined,
              metadata: {
                user_id: fd.get("user_id") || undefined,
                test_type: fd.get("test_type") || undefined,
              },
            };
            try {
              const r = await fetch("/api/keys", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify(payload),
              });
              const j = await r.json();
              if (!r.ok || !j.key) {
                alert(
                  "Failed: " + (j.error?.message || j.detail || JSON.stringify(j)),
                );
                return;
              }
              $("key-modal-value").textContent = j.key;
              $("key-modal").classList.add("show");
              loadKeys();
            } catch (e) {
              alert("Network error: " + e.message);
            } finally {
              btn.disabled = false;
              btn.textContent = "Generate key";
            }
          });

          $("copy-key").addEventListener("click", async () => {
            const v = $("key-modal-value").textContent;
            await navigator.clipboard.writeText(v);
            $("copy-key").textContent = "Copied ✓";
            setTimeout(() => ($("copy-key").textContent = "Copy"), 1500);
          });
          $("close-modal").addEventListener("click", () =>
            $("key-modal").classList.remove("show"),
          );

          $("refresh-keys").addEventListener("click", loadKeys);

          $("smoke-go").addEventListener("click", async () => {
            const key = $("smoke-key").value.trim();
            const out = $("smoke-out");
            if (!key) {
              out.textContent = "paste a virtual key first";
              return;
            }
            out.textContent = "calling…";
            try {
              const r = await fetch("/api/test", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ key }),
              });
              const j = await r.json();
              out.textContent = JSON.stringify(j, null, 2);
            } catch (e) {
              out.textContent = "error: " + e.message;
            }
          });

          checkHealth();
          loadKeys();
          setInterval(checkHealth, 15000);
        </script>
      </body>
    </html>`;
}
