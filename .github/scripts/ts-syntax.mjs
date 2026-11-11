// Whether each TypeScript file still parses. Syntax only: the types are taken out, not checked, since the
// packages these files import are Pi's and are not installed here.
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
let failed = false;
for (const file of process.argv.slice(2)) {
  try { stripTypeScriptTypes(readFileSync(file, "utf8")); }
  catch (e) { failed = true; console.error(`${file}: ${e.message}`); }
}
process.exit(failed ? 1 : 0);
