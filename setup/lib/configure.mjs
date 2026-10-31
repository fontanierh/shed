// JSON edits for install.sh, run with the Node that Pi ships. Every step merges into what is already there.
// Usage: node configure.mjs <step> [args]
//   auth <file>                      add the OPENAI_API_KEY from the environment as the "openai" credential
//   prime-models <vendored> <file>   add our model definitions to Prime's models.json, by provider and id
//   pi-models <vendored> <file>      add our model overrides to Pi's models.json, by provider and model id
//   bridge-defaults <vendored> <file>   set the bridge's per-model default context windows, keeping its token
//   default-model <file> <provider> <id> <thinking>   set the default model only where none is set yet
import fs from "node:fs";
import path from "node:path";

const read = (file) => (fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {});
const write = (file, value, mode = 0o600) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", { mode });
  fs.renameSync(tmp, file);
};

const [step, ...args] = process.argv.slice(2);
switch (step) {
  case "auth": {
    const [file] = args;
    const key = process.env.OPENAI_API_KEY;
    if (!key) throw new Error("OPENAI_API_KEY is not set");
    const auth = read(file);
    const changed = auth.openai?.key !== key;
    auth.openai = { type: "api_key", key };
    write(file, auth);
    console.log(changed ? `  set the OpenAI key in ${file}` : `  OpenAI key already in ${file}`);
    break;
  }
  case "prime-models": {
    const [vendored, file] = args;
    const ours = read(vendored);
    const current = read(file);
    current.providers ??= {};
    for (const [provider, def] of Object.entries(ours.providers ?? {})) {
      const target = (current.providers[provider] ??= {});
      target.models ??= [];
      for (const model of def.models ?? []) {
        const i = target.models.findIndex((m) => m.id === model.id);
        if (i >= 0) target.models[i] = model;
        else target.models.push(model);
      }
    }
    write(file, current, 0o644);
    console.log(`  merged model definitions into ${file}`);
    break;
  }
  case "pi-models": {
    const [vendored, file] = args;
    const ours = read(vendored);
    const current = read(file);
    current.providers ??= {};
    for (const [provider, def] of Object.entries(ours.providers ?? {})) {
      const target = (current.providers[provider] ??= {});
      target.modelOverrides = { ...target.modelOverrides, ...def.modelOverrides };
    }
    write(file, current, 0o644);
    console.log(`  merged model overrides into ${file}`);
    break;
  }
  case "bridge-defaults": {
    const [vendored, file] = args;
    const config = read(file);
    config.defaultContextWindows = { ...config.defaultContextWindows, ...read(vendored).defaultContextWindows };
    write(file, config);
    console.log(`  default context windows in ${file}`);
    break;
  }
  case "default-model": {
    const [file, provider, id, thinking] = args;
    const settings = read(file);
    if (settings.defaultModel) {
      console.log(`  keeping the default model ${settings.defaultProvider ?? "?"}/${settings.defaultModel} in ${file}`);
      break;
    }
    settings.defaultProvider = provider;
    settings.defaultModel = id;
    settings.defaultThinkingLevel ??= thinking;
    write(file, settings, 0o644);
    console.log(`  default model ${provider}/${id} (${settings.defaultThinkingLevel}) in ${file}`);
    break;
  }
  default:
    throw new Error(`unknown step ${step}`);
}
