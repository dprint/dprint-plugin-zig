// @ts-check
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
const rootDir = path.join(__dirname, "../..");
fs.copyFileSync(path.join(rootDir, "zig-out/plugin.wasm"), path.join(__dirname, "plugin.wasm"));
// the license has to be distributed along with the plugin, and the plugin includes zig's std
fs.writeFileSync(
  path.join(__dirname, "LICENSE"),
  fs.readFileSync(path.join(rootDir, "LICENSE"), "utf8")
    + "\n---\n\nZig (its std is compiled into the plugin):\n\n"
    + fs.readFileSync(path.join(rootDir, "third_party/zig/LICENSE"), "utf8"),
);

if (args.length > 0) {
  // update the version based on the first argument
  const packageJsonPath = path.join(__dirname, "package.json");
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
  if (args[0] === "sync-version") {
    packageJson.version = fs.readFileSync(path.join(rootDir, "VERSION"), "utf8").trim();
  } else {
    packageJson.version = args[0];
  }
  fs.writeFileSync(packageJsonPath, JSON.stringify(packageJson, undefined, 2) + "\n");
}
