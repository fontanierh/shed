// Checks that each TypeScript file parses and contains no `: any` or unsafe `as` type casts (per tsbp.md).
// Types are stripped rather than checked with `tsc`, since the `@earendil-works/*` packages are Pi's.
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";

let failed = false;
for (const file of process.argv.slice(2)) {
  const src = readFileSync(file, "utf8");
  try {
    stripTypeScriptTypes(src);
  } catch (e) {
    failed = true;
    console.error(`${file}: ${e.message}`);
    continue;
  }
  const lines = src.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*") || trimmed.startsWith("import ")) {
      continue;
    }
    if (/:\s*any\b|<\s*any\s*>|Record<[^,>]+,\s*any\s*>/.test(line)) {
      failed = true;
      console.error(`${file}:${i + 1}: avoid 'any'; use 'unknown' and narrow at the boundary`);
    }
    // Disallow ` as Type` assertions except ` as const`.
    for (const match of line.matchAll(/\bas\s+([A-Za-z_$][\w$]*)/g)) {
      if (match[1] !== "const") {
        failed = true;
        console.error(`${file}:${i + 1}: avoid 'as ${match[1]}' cast; validate with a type guard instead`);
      }
    }
  }
}
process.exit(failed ? 1 : 0);
