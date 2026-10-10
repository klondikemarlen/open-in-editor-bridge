import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

const pluginSource = new URL("../lib/open_in_editor_bridge/vite.mjs", import.meta.url);
const session = "a".repeat(64);

async function pluginFor(manifestText) {
  const directory = await mkdtemp(join(tmpdir(), "open-in-editor-bridge-"));
  const modulePath = join(directory, "vite.mjs");
  await writeFile(modulePath, await readFile(pluginSource));
  if (manifestText !== undefined) {
    await writeFile(join(directory, "session.json"), manifestText);
  }
  const { default: openInEditorBridge } = await import(pathToFileURL(modulePath).href);
  return {
    createPlugin: openInEditorBridge,
    async cleanup() {
      await rm(directory, { recursive: true, force: true });
    },
  };
}

function configuredProxy(plugin, proxy = {}) {
  const config = { server: { proxy } };
  plugin.config(config);
  return config.server.proxy;
}

test("when callers supply hostile selectors, routing preserves the checkout and encoded location", async (t) => {
  // Arrange
  const { createPlugin, cleanup } = await pluginFor(
    JSON.stringify({ session, target: "http://host.docker.internal:4567" }),
  );
  t.after(cleanup);

  const existing = {
    "/__open-in-editor": { target: "http://untrusted.invalid" },
    "^/__open-in-editor$": { target: "http://also-untrusted.invalid" },
    "^/__open-in-editor(?:\\?|$)": { target: "http://hostile-checkout.invalid" },
    "/": { target: "http://ordinary-app.invalid" },
  };
  const requestUrl = "/__open-in-editor?file=%2Fusr%2Fsrc%2Fapp%252Fname.rb%3A12%3A4&session=wrong&%73ession=another&keep=a%2Fb";

  // Act
  const proxy = configuredProxy(createPlugin(), existing);
  const route = Object.entries(proxy).find(([key]) => key.startsWith("^/__open-in-editor"));
  const rewritten = route[1].rewrite(requestUrl);

  // Assert
  assert.equal(route[1].target, "http://host.docker.internal:4567");
  assert.equal(Object.keys(proxy)[0], route[0], "editor routing precedes broad application proxies");

  assert.equal(
    rewritten,
    `/__open-in-editor?file=%2Fusr%2Fsrc%2Fapp%252Fname.rb%3A12%3A4&keep=a%2Fb&session=${session}`,
  );
});

test("when requests target neighboring or control paths, the editor proxy does not match", async (t) => {
  // Arrange
  const { createPlugin, cleanup } = await pluginFor(
    JSON.stringify({ session, target: "http://host.docker.internal:4567" }),
  );
  t.after(cleanup);

  // Act
  const proxy = configuredProxy(createPlugin());
  const matcher = new RegExp(Object.keys(proxy)[0].slice(1));

  // Assert
  assert.equal(matcher.test("/__open-in-editor"), true);
  assert.equal(matcher.test("/__open-in-editor?file=app.rb"), true);
  assert.equal(matcher.test("/__open-in-editor/"), false);
  assert.equal(matcher.test("/__open-in-editor/health"), false);
  assert.equal(matcher.test("/health"), false);
  assert.equal(matcher.test("/sessions"), false);
  assert.equal(matcher.test("/release"), false);
});

test("when the checkout identity is missing or malformed, plugin creation fails safely", async (t) => {
  // Arrange
  const manifests = [
    undefined,
    "",
    "not json",
    JSON.stringify({ session: "", target: "http://host.docker.internal:4567" }),
    JSON.stringify({ session, target: "https://host.docker.internal:4567" }),
    JSON.stringify({ session, target: "http://user@host.docker.internal:4567" }),
    JSON.stringify({ session, target: "http://host.docker.internal:4567/health" }),
  ];

  for (const manifest of manifests) {
    const { createPlugin, cleanup } = await pluginFor(manifest);
    t.after(cleanup);

    // Act
    const create = () => createPlugin();

    // Assert
    assert.throws(create, /requires a valid Docker session manifest/);
  }
});
