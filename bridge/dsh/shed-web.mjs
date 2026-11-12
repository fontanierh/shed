// Shed's web provider for DeepSeek Harness: dsh's own web_search and web_fetch tools run through it, and it runs
// Shed's `shed-web` command, which holds the provider's key (Firecrawl). The bridge loads this plugin, and pins
// dsh's web service to it, only when a web provider is set up on this Mac.

import { execFile } from "node:child_process";

// dsh's own error type, so its tools report failures as web errors; resolved from the profile's packages.
let WebError;
try {
  ({ WebError } = await import("@deepseek-ai/dsh-web"));
} catch {
  WebError = class extends Error {
    constructor(message, code) {
      super(message);
      this.code = code;
    }
  };
}

export const name = "shed-web";
export const inject = ["web"];

const ID = "shed";

export function apply(ctx, config = {}) {
  const command = config.command || "shed-web";

  const run = (subcommand, options, target, signal) =>
    new Promise((resolve, reject) => {
      execFile(
        command,
        [subcommand, ...options, "--json", "--", target],
        { signal, maxBuffer: 64 << 20, timeout: 180_000 },
        (error, stdout, stderr) => {
          if (signal?.aborted) return reject(new WebError("the web request was cancelled", "WEB_ABORTED"));
          if (error) {
            const message = String(stderr || error.message).trim().replace(/^shed-web: /, "");
            return reject(new WebError(message || "shed-web failed", "WEB_PROVIDER_ERROR"));
          }
          try {
            resolve(JSON.parse(stdout));
          } catch {
            reject(new WebError("shed-web printed something that isn't JSON", "WEB_PROVIDER_ERROR"));
          }
        },
      );
    });

  ctx.web.registerSearchProvider({
    id: ID,
    available: () => true,
    async search(request, signal) {
      const limit = String(request.maxResults ?? 8);
      const result = await run("search", ["--limit", limit], request.query, signal);
      const sources = (result.sources ?? []).map((s) => ({
        url: s.url,
        ...(s.title ? { title: s.title } : {}),
        ...(s.snippet ? { snippet: s.snippet } : {}),
        ...(s.publishedAt ? { publishedAt: s.publishedAt } : {}),
      }));
      return { sources, truncated: false };
    },
  });

  ctx.web.registerFetchProvider({
    id: ID,
    available: () => true,
    async fetch(request, signal) {
      const page = await run("fetch", [], request.url, signal);
      let content = page.markdown ?? "";
      if (page.markdownFile) {
        content += `\n\n[The page is longer: only its beginning is above. All of it, as Markdown: ${page.markdownFile}]`;
      }
      return {
        url: page.url || request.url,
        statusCode: page.statusCode ?? 200,
        body: { kind: "text", content },
        truncated: Boolean(page.truncated),
      };
    },
  });
}
