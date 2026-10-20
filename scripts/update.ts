/**
 * This script checks for a new stable Zig release and then automatically
 * publishes a new version of the plugin if so.
 *
 * The formatter is part of Zig's std, so updating means building the plugin with
 * the new Zig. The version is the `minimum_zig_version` in build.zig.zon, which
 * build.zig requires exactly and CI's setup-zig installs.
 */
import { $, semver } from "automation";
import { aiFixZigUpdate } from "./ai_fix.ts";
import { publishRelease } from "./publish_release.ts";

const rootDirPath = $.path(import.meta.dirname!).parentOrThrow();
const manifestPath = rootDirPath.join("build.zig.zon");
const zigLicensePath = rootDirPath.join("third_party/zig/LICENSE");
const minimumZigVersionRe = /^(\s*\.minimum_zig_version = ")([^"]+)(",)$/m;

interface ZigRelease {
  src: ZigTarball;
  [target: string]: unknown;
}

interface ZigTarball {
  tarball: string;
  shasum: string;
}

if (import.meta.main) {
  await main();
}

async function main() {
  const currentVersion = getZigVersion();

  $.logStep("Getting latest version...");
  const releases = await $.request("https://ziglang.org/download/index.json")
    .json<Record<string, ZigRelease>>();
  const latestVersion = getLatestStableVersion(releases);
  if (semver.compare(semver.parse(currentVersion), semver.parse(latestVersion)) >= 0) {
    $.log("No new update found. Exiting.");
    Deno.exit(0);
  }

  $.log(`Found new version: ${currentVersion} -> ${latestVersion}`);
  const isPatchBump = semver.parse(currentVersion).major === semver.parse(latestVersion).major
    && semver.parse(currentVersion).minor === semver.parse(latestVersion).minor;

  $.logStep(`Installing Zig ${latestVersion}...`);
  const zigDirPath = await installZig(releases[latestVersion], latestVersion);

  $.logStep("Updating build.zig.zon...");
  setZigVersion(latestVersion);
  // the plugin's license text includes zig's license, since its std is compiled in
  zigLicensePath.writeTextSync(zigDirPath.join("LICENSE").readTextSync());

  // Verify the update. A clean patch bump publishes exactly as before. A minor
  // bump always gets an AI review (the std usually changes in ways that need the
  // plugin updated, and zig fmt may have changed), and a patch bump that fails
  // the checks gets an AI fix attempt.
  $.logStep("Running checks (zig build test + wasm build)...");
  const pathSeparator = Deno.build.os === "windows" ? ";" : ":";
  const env = { PATH: `${zigDirPath}${pathSeparator}${Deno.env.get("PATH")}` };
  const checks = await runChecks(env);

  if (!isPatchBump || !checks.passed) {
    if (checks.passed) {
      $.logStep("Minor Zig update — running AI review...");
    } else {
      $.logStep(`${isPatchBump ? "Patch" : "Minor"} update failed the checks — running AI fix...`);
    }
    await aiFixZigUpdate({
      isPatchBump,
      fromVersion: currentVersion,
      toVersion: latestVersion,
      zigDirPath: zigDirPath.toString(),
      zigSourceUrl: releases[latestVersion].src.tarball,
      checksPassed: checks.passed,
      // hand the failing output to the AI so it can go straight to fixing
      // instead of re-running the checks just to rediscover the errors.
      checkOutput: checks.output,
      env,
    });

    // the AI must leave the project in a passing state, otherwise fail the
    // workflow (nothing gets published and the maintainer is notified).
    $.logStep("Re-running checks after AI changes...");
    await assertChecks(env);
  }

  if (Deno.args.includes("--skip-publish")) {
    Deno.exit(0);
  }

  $.logStep("Committing Zig version bump commit...");
  await $`git add .`;
  const message = `${isPatchBump ? "fix" : "feat"}: update to Zig ${latestVersion}`;
  await $`git commit -m ${message}`;

  await publishRelease(isPatchBump ? "patch" : "minor");
}

/** Gets the newest Zig release that isn't a development build. */
function getLatestStableVersion(releases: Record<string, ZigRelease>) {
  const versions = Object.keys(releases)
    .map((key) => semver.tryParse(key))
    .filter((version) => version != null && version.prerelease?.length === 0)
    .sort((a, b) => semver.compare(b!, a!));
  if (versions.length === 0) {
    throw new Error("Could not find a stable Zig release in https://ziglang.org/download/index.json.");
  }
  const version = semver.format(versions[0]!);
  $.logLight("Latest Zig version:", version);
  return version;
}

/** Downloads and extracts the Zig release for this machine, returning its directory. */
async function installZig(release: ZigRelease, version: string) {
  const os = Deno.build.os === "darwin" ? "macos" : Deno.build.os;
  const tarball = release[`${Deno.build.arch}-${os}`] as ZigTarball | undefined;
  if (tarball == null) {
    throw new Error(`Zig ${version} has no release for ${Deno.build.arch}-${os}.`);
  }

  // extracted into an empty directory of its own
  const tempDirPath = $.path(await Deno.makeTempDir({ prefix: "zig-" }));
  const archivePath = tempDirPath.join(tarball.tarball.split("/").pop()!);
  await $.request(tarball.tarball).showProgress().pipeToPath(archivePath);
  const hash = await crypto.subtle.digest("SHA-256", new Uint8Array(archivePath.readBytesSync()));
  const shasum = Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
  if (shasum !== tarball.shasum) {
    throw new Error(`Checksum mismatch for ${tarball.tarball}. Expected ${tarball.shasum}, but got ${shasum}.`);
  }

  const extractDirPath = tempDirPath.join("extracted");
  extractDirPath.mkdirSync();
  if (archivePath.toString().endsWith(".zip")) {
    await $`unzip -q ${archivePath} -d ${extractDirPath}`;
  } else {
    await $`tar -xJf ${archivePath} -C ${extractDirPath}`;
  }
  const zigDirPath = Array.from(extractDirPath.readDirSync())[0].path;
  $.logLight(`Installed Zig ${version} to`, zigDirPath.toString());
  return zigDirPath;
}

// the checks that must pass before publishing. The spec tests compare the
// plugin's output to the new Zig's `zig fmt`. `inheritPiped` +
// `captureCombined` streams the output to the CI log live while also capturing
// it so a failure can be handed to the AI.
async function runChecks(env: Record<string, string>): Promise<{ passed: boolean; output: string }> {
  const results = [];
  for (const command of checkCommands(env)) {
    results.push(await capture(command()));
  }
  const failures = results.filter((r) => r.code !== 0);
  return {
    passed: failures.length === 0,
    output: failures.map((r) => r.combined).join("\n\n"),
  };
}

function capture(command: ReturnType<typeof $>) {
  return command
    .stdout("inheritPiped")
    .stderr("inheritPiped")
    .captureCombined()
    .noThrow();
}

// same checks as `runChecks`, but throws on the first failure so the workflow
// aborts before anything is committed, tagged, or published.
async function assertChecks(env: Record<string, string>): Promise<void> {
  for (const command of checkCommands(env)) {
    await command();
  }
}

// a function (not a top-level const) so it is hoisted -- `runChecks` is called
// from `main` before a const declared here would be initialized.
function checkCommands(env: Record<string, string>) {
  return [
    () => $`zig build test --summary all`.cwd(rootDirPath).env(env),
    () => $`zig build`.cwd(rootDirPath).env(env),
  ];
}

function getZigVersion() {
  const version = manifestPath.readTextSync().match(minimumZigVersionRe)?.[2];
  if (version == null) {
    throw new Error("Could not find the minimum_zig_version in build.zig.zon.");
  }
  $.logLight("Found Zig version in build.zig.zon:", version);
  return version;
}

function setZigVersion(version: string) {
  const text = manifestPath.readTextSync();
  manifestPath.writeTextSync(text.replace(minimumZigVersionRe, `$1${version}$3`));
}
