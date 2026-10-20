/**
 * Reconciles this plugin with a new Zig release using OpenAI Codex, in two
 * stages that each run Codex in a session of its own:
 *
 *   1. a Codex agentic session edits the source and runs the checks until they
 *      pass (fixing breakage from changes to Zig's std, build system, or
 *      `zig fmt`), then
 *   2. a SEPARATE reviewer session reviews the result with Codex, so it can
 *      investigate (read the Zig source, grep the repo). It is instructed to
 *      review only and not modify anything. If it finds blocking issues they are
 *      fed back to the stage-1 Codex for another pass, bounded by
 *      `REVIEW_MAX_ROUNDS`. If it still isn't approved, this throws so the
 *      workflow fails and nothing is published.
 *
 * Two situations call this:
 *   - a patch bump that failed the checks (fix the breakage), and
 *   - any minor bump (review for changes to `zig fmt` and to how it reports
 *     parse errors even when it still compiles).
 *
 * Both stages use the default model of the Codex CLI, which is installed at
 * its latest version when it is missing, so they move to a new model when
 * Codex does. Set `CODEX_MODEL` or `REVIEW_MODEL` to pin the model of a stage.
 *
 * Codex must NOT commit or push -- `update.ts` captures the working tree
 * changes into the existing Zig bump commit afterwards.
 */
import { $ } from "automation";

export interface AiFixOptions {
  /** true for a patch bump, false for a minor/major bump. */
  isPatchBump: boolean;
  /** Zig version currently in build.zig.zon (before the bump). */
  fromVersion: string;
  /** Zig version being upgraded to. */
  toVersion: string;
  /** Directory of the new Zig, which has its std in `lib/std`. */
  zigDirPath: string;
  /** URL of the source tarball of the new Zig, which has `zig fmt` in `src/fmt.zig`. */
  zigSourceUrl: string;
  /** Whether the checks (zig build test + wasm build) already passed. */
  checksPassed: boolean;
  /** Combined output of the failing checks (empty when `checksPassed`). */
  checkOutput: string;
  /** Environment that puts the new Zig on the path. */
  env: Record<string, string>;
}

/** Max number of times the reviewer may send changes back to Codex. */
const REVIEW_MAX_ROUNDS = 2;

export async function aiFixZigUpdate(options: AiFixOptions): Promise<void> {
  const apiKey = requireApiKey();
  await ensureCodexInstalled();
  await codexLogin(apiKey);

  // stage 1: let Codex reconcile the update.
  await runCodex(buildFixPrompt(options), options.env);

  // stage 2: independent second-model review, with a bounded refix loop.
  for (let round = 1;; round++) {
    const review = await reviewChanges(options);
    logReview(review);
    if (review.approved) {
      return;
    }
    if (round > REVIEW_MAX_ROUNDS) {
      const blocking = review.issues.filter((i) => i.severity === "blocking");
      throw new Error(
        `AI reviewer did not approve after ${REVIEW_MAX_ROUNDS} refix round(s). Blocking issues:\n`
          + blocking.map((i) => `  - ${i.description}`).join("\n"),
      );
    }
    $.logStep(`Reviewer requested changes — Codex refix round ${round}...`);
    await runCodex(buildRefixPrompt(review), options.env);
  }
}

// stage 1: Codex ---------------------------------------------------------------

async function runCodex(prompt: string, env: Record<string, string>): Promise<void> {
  const args = ["exec", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"];
  const model = Deno.env.get("CODEX_MODEL");
  if (model) {
    args.push("--model", model);
  }
  args.push(prompt);

  $.logStep("Running Codex...");
  await $`codex ${args}`.env(env);
}

function buildFixPrompt(options: AiFixOptions): string {
  const { isPatchBump, fromVersion, toVersion, checksPassed, checkOutput } = options;

  const situation = checksPassed
    ? `Zig was upgraded from ${fromVersion} to ${toVersion} (a ${
      isPatchBump ? "patch" : "minor"
    } bump). The project already compiles and the checks pass, but the new Zig may have changed \`zig fmt\` (its \`src/fmt.zig\`, like how it reads the source or picks ZON mode) or how it reports parse errors (\`lowerAstErrors\` in \`std.zig.AstGen\` and \`std.zig.ZonGen\`, or the rendering in \`std.zig.ErrorBundle\`) in ways the spec tests don't cover, which this plugin mirrors by hand.`
    : `Zig was upgraded from ${fromVersion} to ${toVersion} and the checks fail (the project no longer builds, the unit tests fail, or the spec tests that compare the plugin to the new \`zig fmt\` fail). This is usually because Zig's std changed (\`std.zig.Ast\`, \`std.Io.Writer\`, \`std.json\`, \`std.mem.Allocator\`, \`std.heap.wasm_allocator\`, \`std.process\`, \`std.Io.Dir\`), because the build system API used by \`build.zig\` changed, or because \`zig fmt\` now formats or reports errors differently.`;

  const failureOutput = checkOutput.trim().length > 0
    ? [
      ``,
      `The checks currently fail with the output below. Use it as your starting point instead of re-running the checks just to rediscover the errors:`,
      "```",
      truncateHead(checkOutput.trim()),
      "```",
    ]
    : [];

  return [
    `You are updating "dprint-plugin-zig", a dprint Wasm plugin written in Zig that formats Zig and ZON files with Zig's own formatter (\`std.zig.Ast.parse\` and \`render\`, which is what \`zig fmt\` uses). It is compiled to a zero-import wasm32-freestanding module that implements the dprint Wasm plugin interface by hand.`,
    ``,
    situation,
    ...failureOutput,
    ``,
    `Your goal: make the checks pass AND keep the plugin's output byte-identical to \`zig fmt\` of Zig ${toVersion}, including its parse error messages. Do NOT commit or push; only edit files in the working tree.`,
    ``,
    describeWiring(),
    ``,
    `The new Zig is on the path, and its std is in \`${options.zigDirPath}/lib/std\`. \`zig fmt\` itself (\`src/fmt.zig\`) isn't in the binary release, so download the source tarball from ${options.zigSourceUrl} into an empty temp directory and extract \`src/fmt.zig\` to read it. Compare it, \`lowerAstErrors\` in \`lib/std/zig/AstGen.zig\` and \`lib/std/zig/ZonGen.zig\`, \`addZirErrorMessages\`/\`addZoirErrorMessages\` and \`renderErrorMessage\` in \`lib/std/zig/ErrorBundle.zig\`, and \`readSourceFileToEndAlloc\` in \`lib/std/zig.zig\` against \`src/format_text.zig\`.`,
    ``,
    `Rules:`,
    `1. Mirror upstream exactly. If \`zig fmt\` changed how it reads the source (byte order marks, encodings), how it picks ZON mode, or how parse errors are lowered or rendered, update \`src/format_text.zig\` to match and add a unit test for it.`,
    `2. \`zig fmt\` has no formatting options, so the plugin has none. If \`zig fmt\` gained a formatting option, do NOT add it; say so in your final message instead, since it needs a decision from the maintainer.`,
    `3. If a test fails only because \`zig fmt\` intentionally formats some code or reports an error differently now, update that test's expected output and explain what changed in your final message. The spec tests in \`tests/spec_test.zig\` compare against the real \`zig fmt\`, so never change them or the fixtures in \`tests/specs\` to hide a difference. Never change an expected output to hide a bug in this plugin.`,
    `4. Do NOT edit \`README.md\`. Its documentation is maintained separately, so leave it untouched.`,
    `5. Preserve the existing code style and run \`zig fmt build.zig main.zig src tests/spec_test.zig\`. New comments start lowercase unless multiple sentences.`,
    `6. The plugin must keep compiling to a module with no imports: check that \`wasm-objdump -x -j Import zig-out/plugin.wasm\` (or an equivalent) shows no import section after \`zig build\`, if a tool for it is available.`,
    `7. When done, ALL of these must pass -- iterate until they are all clean:`,
    `     zig build test --summary all`,
    `     zig build`,
    `8. Do not change the plugin's own version in the VERSION file, do not change \`minimum_zig_version\` in build.zig.zon (it's already ${toVersion}), do not run git commit, and do not push.`,
  ].join("\n");
}

function buildRefixPrompt(review: ReviewResult): string {
  return [
    `An independent reviewer examined your changes to dprint-plugin-zig and found issues that must be fixed. Address every blocking issue below, keeping \`zig build test --summary all\` and \`zig build\` green. Do not commit or push.`,
    ``,
    `Reviewer summary: ${review.summary}`,
    ``,
    `Issues:`,
    ...review.issues.map((i) => `  - [${i.severity}] ${i.description}`),
    ``,
    describeWiring(),
  ].join("\n");
}

function describeWiring(): string {
  return [
    `How the plugin is wired (keep all of these consistent with each other):`,
    `- \`main.zig\` -> the Wasm exports of the dprint plugin interface (schema version 4), which call into \`src/plugin.zig\`.`,
    `- \`src/plugin.zig\` -> the plugin's state: the shared bytes, the registered configs, and formatting.`,
    `- \`src/format_text.zig\` -> \`formatText\` decodes the source like \`std.zig.readSourceFileToEndAlloc\`, parses it with \`std.zig.Ast.parse\` (ZON mode for \`.zon\` files like \`zig fmt\`), renders it with \`render\`, and renders parse errors the way \`zig fmt\` prints them (without the file path).`,
    `- \`src/config.zig\` -> the configuration, which only has diagnostics for unknown properties, since \`zig fmt\` has no options.`,
    `- \`build.zig\` -> builds \`zig-out/plugin.wasm\` and the unit and spec tests. It requires the Zig version in build.zig.zon exactly.`,
    `- \`tests/spec_test.zig\` -> formats each file in \`tests/specs\` with the plugin and with the real \`zig fmt\`, and checks they're the same.`,
  ].join("\n");
}

// keep the tail of long check output -- the errors and the summary are at the
// end, which is the most useful part for the AI.
function truncateHead(text: string, max = 20_000): string {
  return text.length > max ? `... (truncated)\n${text.slice(text.length - max)}` : text;
}

// stage 2: independent reviewer ------------------------------------------------

interface ReviewResult {
  approved: boolean;
  summary: string;
  issues: ReviewIssue[];
}

interface ReviewIssue {
  severity: "blocking" | "nit";
  description: string;
}

// The reviewer runs Codex too so it can actually investigate (read the Zig
// source, grep the repo, verify against the real upstream code). Its verdict is
// captured as JSON via --output-last-message.
//
// NOTE: we deliberately do NOT use `--sandbox read-only` here. That makes Codex
// wrap commands in bubblewrap, which cannot set up its network namespace on the
// GitHub Actions runner ("bwrap: loopback: Failed RTM_NEWADDR: Operation not
// permitted"), so every command the reviewer runs fails before executing. We
// use the same no-sandbox mode as the fixer and enforce read-only via the
// prompt instead. (CI is itself a throwaway VM, and the final check gate in
// update.ts re-verifies whatever ends up in the working tree.)
async function reviewChanges(options: AiFixOptions): Promise<ReviewResult> {
  // the reviewer starts without the context of the fixer, which is what makes
  // it a second opinion. It uses the default model of Codex unless one is set.
  const model = Deno.env.get("REVIEW_MODEL");

  // record intent-to-add so any files Codex created also show in `git diff`.
  await $`git add -N .`.quiet();

  const outputFile = await Deno.makeTempFile({ prefix: "codex-review-", suffix: ".json" });
  try {
    $.logStep(`Reviewing changes with Codex (${model ?? "default model"})...`);
    const args = ["exec", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"];
    if (model) {
      args.push("--model", model);
    }
    args.push("--output-last-message", outputFile, buildReviewPrompt(options));
    await $`codex ${args}`.env(options.env);
    return parseReview(await Deno.readTextFile(outputFile));
  } finally {
    await Deno.remove(outputFile).catch(() => {});
  }
}

function buildReviewPrompt(options: AiFixOptions): string {
  return [
    `You are an independent reviewer for dprint-plugin-zig, a dprint Wasm plugin written in Zig that formats Zig and ZON files with Zig's own formatter, so that its output is byte-identical to \`zig fmt\`. Zig was just upgraded from ${options.fromVersion} to ${options.toVersion} and another AI edited this plugin to reconcile it. Review the UNCOMMITTED working-tree changes.`,
    `IMPORTANT: this is REVIEW ONLY. Read any files and run read-only commands (git diff, cat, grep, find, etc.) to investigate, but you MUST NOT edit, create, or delete any files in the repo, and MUST NOT run git commit or git push. Leave the working tree exactly as you found it. You may download and extract the Zig source into a temp directory outside the repo.`,
    ``,
    `Investigate as needed:`,
    `- Run \`git --no-pager diff\` (and \`git status\`) to see exactly what changed, including any new files.`,
    `- Verify against the REAL Zig ${options.toVersion}: its std is in \`${options.zigDirPath}/lib/std\`, and \`zig fmt\` (\`src/fmt.zig\`) is in the source tarball at ${options.zigSourceUrl}.`,
    `- Read the plugin files to confirm they are consistent with each other and with upstream.`,
    ``,
    describeWiring(),
    ``,
    `Verify specifically:`,
    `- \`src/format_text.zig\` still mirrors how \`zig fmt\` reads the source and picks ZON mode, how \`lowerAstErrors\` in AstGen and ZonGen lowers parse errors, and how ErrorBundle renders them.`,
    `- No formatting option was added to the plugin (\`zig fmt\` has none). If \`zig fmt\` gained one, that is a blocking issue to report rather than something to add.`,
    `- The spec tests and the fixtures in \`tests/specs\` weren't changed to hide a difference from \`zig fmt\`, and any changed expected output in the unit tests is explained by an intentional change in Zig ${options.toVersion}, not by a bug in this plugin. An unexplained change is a blocking issue.`,
    `- README.md was NOT modified (its documentation is maintained separately); flag any README.md change as a blocking issue.`,
    `- No obvious correctness bugs (including memory leaks, which the tests' allocator catches), and code style matches the surrounding code.`,
    ``,
    `When done, your FINAL message must be ONLY a JSON object (no markdown code fences, no extra prose) of exactly this shape:`,
    `{"approved": true|false, "summary": "one sentence", "issues": [{"severity": "blocking"|"nit", "description": "..."}]}`,
    `Set approved=false if there is any blocking issue; nits alone do not block.`,
  ].join("\n");
}

function parseReview(message: string): ReviewResult {
  const review = JSON.parse(extractJsonObject(message)) as ReviewResult;
  if (typeof review.approved !== "boolean" || !Array.isArray(review.issues)) {
    throw new Error(`Codex review returned malformed JSON:\n${message}`);
  }
  return review;
}

// Codex is instructed to emit only JSON, but tolerate an accidental code fence
// or surrounding prose by extracting the outermost { ... } object.
function extractJsonObject(text: string): string {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) {
    throw new Error(`Could not find a JSON object in Codex review output:\n${text}`);
  }
  return text.slice(start, end + 1);
}

function logReview(review: ReviewResult): void {
  $.log(`Review: ${review.approved ? "approved" : "changes requested"} — ${review.summary}`);
  for (const issue of review.issues) {
    $.logLight(`  [${issue.severity}] ${issue.description}`);
  }
}

// setup ------------------------------------------------------------------------

function requireApiKey(): string {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is not set. It is required to run the AI fixer and reviewer.");
  }
  return apiKey;
}

async function ensureCodexInstalled(): Promise<void> {
  const found = await $`codex --version`.noThrow().quiet();
  if (found.code === 0) {
    return;
  }
  $.logStep("Installing OpenAI Codex CLI...");
  await $`npm install -g @openai/codex`;
}

// `codex exec` does not read OPENAI_API_KEY on its own -- it needs credentials
// stored via `codex login` first, otherwise its requests go out with no auth
// header and the API returns 401. The key is piped over stdin so it never
// appears in the process arguments.
async function codexLogin(apiKey: string): Promise<void> {
  $.logStep("Authenticating Codex with the OpenAI API key...");
  await $`codex login --with-api-key`.stdinText(apiKey);
}
