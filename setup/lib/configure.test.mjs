import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "configure.mjs");

function run(args, env = {}) {
  execFileSync(process.execPath, [SCRIPT, ...args], {
    env: { PATH: process.env.PATH, ...env },
    stdio: "pipe",
  });
}

test("configure.mjs merges auth, models, bridge defaults, default-model, opencodex and web idempotently", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shed-configure-"));
  try {
    // auth: writes 0600 and preserves existing providers
    const authFile = path.join(dir, "auth.json");
    fs.writeFileSync(authFile, JSON.stringify({ mistral: { type: "api_key", key: "keep-me" } }));
    run(["auth", authFile], { OPENAI_API_KEY: "test-openai-key" });
    const auth = JSON.parse(fs.readFileSync(authFile, "utf8"));
    assert.deepEqual(auth, {
      mistral: { type: "api_key", key: "keep-me" },
      openai: { type: "api_key", key: "test-openai-key" },
    });
    assert.equal(fs.statSync(authFile).mode & 0o777, 0o600);

    // prime-models: adds new models and replaces matching model ids in place
    const vendoredPrime = path.join(dir, "vendored-prime.json");
    const primeModels = path.join(dir, "prime-models.json");
    fs.writeFileSync(
      vendoredPrime,
      JSON.stringify({
        providers: {
          openai: { models: [{ id: "m1", contextWindow: 400000 }, { id: "m2", contextWindow: 128000 }] },
        },
      }),
    );
    fs.writeFileSync(
      primeModels,
      JSON.stringify({
        providers: {
          openai: { models: [{ id: "m1", contextWindow: 100000 }, { id: "custom", contextWindow: 64000 }] },
        },
      }),
    );
    run(["prime-models", vendoredPrime, primeModels]);
    assert.deepEqual(JSON.parse(fs.readFileSync(primeModels, "utf8")).providers.openai.models, [
      { id: "m1", contextWindow: 400000 },
      { id: "custom", contextWindow: 64000 },
      { id: "m2", contextWindow: 128000 },
    ]);

    // pi-models: merges modelOverrides
    const vendoredPi = path.join(dir, "vendored-pi.json");
    const piModels = path.join(dir, "pi-models.json");
    fs.writeFileSync(
      vendoredPi,
      JSON.stringify({ providers: { anthropic: { modelOverrides: { "c-1": { maxTokens: 16000 } } } } }),
    );
    fs.writeFileSync(
      piModels,
      JSON.stringify({ providers: { anthropic: { modelOverrides: { user: { maxTokens: 8000 } } } } }),
    );
    run(["pi-models", vendoredPi, piModels]);
    assert.deepEqual(JSON.parse(fs.readFileSync(piModels, "utf8")).providers.anthropic.modelOverrides, {
      user: { maxTokens: 8000 },
      "c-1": { maxTokens: 16000 },
    });

    // bridge-defaults + opencodex + web: preserves token and custom settings
    const vendoredBridge = path.join(dir, "bridge-defaults.json");
    const configFile = path.join(dir, "config.json");
    fs.writeFileSync(vendoredBridge, JSON.stringify({ defaultContextWindows: { "openai/m1": 272000 } }));
    fs.writeFileSync(configFile, JSON.stringify({ token: "keep-token", defaultContextWindows: { custom: 100000 } }));
    run(["bridge-defaults", vendoredBridge, configFile]);
    run(["opencodex", configFile, "off"]);
    assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).opencodex, false);
    run(["opencodex", configFile, "on"]);
    assert.equal(JSON.parse(fs.readFileSync(configFile, "utf8")).opencodex, undefined);
    run(["web", configFile], { FIRECRAWL_API_KEY: "test-fc-key" });
    const cfg = JSON.parse(fs.readFileSync(configFile, "utf8"));
    assert.equal(cfg.token, "keep-token");
    assert.deepEqual(cfg.defaultContextWindows, { custom: 100000, "openai/m1": 272000 });
    assert.deepEqual(cfg.web, { provider: "firecrawl", firecrawlApiKey: "test-fc-key" });

    // default-model: sets when missing, leaves user's choice untouched when already set
    const settingsFile = path.join(dir, "settings.json");
    run(["default-model", settingsFile, "opencodex", "m1", "high"]);
    run(["default-model", settingsFile, "other", "m2", "low"]);
    assert.deepEqual(JSON.parse(fs.readFileSync(settingsFile, "utf8")), {
      defaultProvider: "opencodex",
      defaultModel: "m1",
      defaultThinkingLevel: "high",
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
