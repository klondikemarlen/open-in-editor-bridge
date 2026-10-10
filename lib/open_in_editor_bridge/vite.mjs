import { readFileSync } from "node:fs";

const sessionManifestPath = new URL("./session.json", import.meta.url);
const editorRouteKey = "^/__open-in-editor(?:\\?|$)";

function readSession() {
  try {
    const manifest = JSON.parse(readFileSync(sessionManifestPath, "utf8"));
    if (
      !manifest ||
      typeof manifest.session !== "string" ||
      !/^[a-f0-9]{64}$/.test(manifest.session) ||
      typeof manifest.target !== "string"
    ) {
      throw new Error("Invalid checkout identity");
    }

    const target = new URL(manifest.target);
    if (
      target.protocol !== "http:" ||
      !target.hostname ||
      target.username ||
      target.password ||
      target.pathname !== "/" ||
      target.search ||
      target.hash
    ) {
      throw new Error("Invalid bridge target");
    }

    return { session: manifest.session, target: target.origin };
  } catch (cause) {
    throw new Error("OpenInEditorBridge requires a valid Docker session manifest; start Vite through OpenInEditorBridge.compose.", { cause });
  }
}

function withSession(requestUrl, session) {
  const queryStart = requestUrl.indexOf("?");
  if (queryStart === -1) return `${requestUrl}?session=${encodeURIComponent(session)}`;

  const path = requestUrl.slice(0, queryStart);
  const query = requestUrl.slice(queryStart + 1);
  const retained = query.split("&").filter((part) => {
    const separator = part.indexOf("=");
    const rawName = separator === -1 ? part : part.slice(0, separator);
    try {
      return decodeURIComponent(rawName.replace(/\+/g, " ")) !== "session";
    } catch {
      return true;
    }
  });
  retained.push(`session=${encodeURIComponent(session)}`);
  return `${path}?${retained.join("&")}`;
}

export default function openInEditorBridge() {
  const identity = readSession();

  return {
    name: "open-in-editor-bridge",
    enforce: "post",
    config(config) {
      const existing = { ...config.server?.proxy };
      delete existing["/__open-in-editor"];
      delete existing["^/__open-in-editor$"];
      delete existing[editorRouteKey];

      config.server ??= {};
      config.server.proxy = {
        [editorRouteKey]: {
          target: identity.target,
          changeOrigin: true,
          rewrite: (requestUrl) => withSession(requestUrl, identity.session),
        },
        ...existing,
      };
    },
  };
}
