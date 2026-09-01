#!/usr/bin/env node
/**
 * Firstmate-owned no-mistakes validation boundary.
 *
 * Firstmate workers resolve the bare `no-mistakes` command through the tracked
 * bin/no-mistakes symlink to this file. bin/fm-spawn.sh supplies the native
 * binary so this boundary can validate policy, account a
 * machine-shared slot, and then invoke no-mistakes without recursively calling
 * itself.
 *
 * Guarded native boundaries are normalized `axi run`, `axi respond`, and
 * `rerun` forms, including root flags before those commands and excluding help
 * and version forms. Every other command is passed through unchanged. A
 * globally absent policy therefore preserves the old path byte-for-byte apart
 * from one exec hop, while malformed configured policy refuses only guarded
 * validation work.
 *
 * Local policy lives at config/no-mistakes-policy.json under
 * FM_NO_MISTAKES_POLICY_HOME (falling back to FM_HOME, then the tracked root).
 * Schema v1 is:
 *   {"version":1,"allowedAgents":["<identity>",...],"maxConcurrent":<integer>}
 * `auto` is never a positive identity and is rejected in allowedAgents. The
 * complete selector is read from global config plus the freshly fetched trusted
 * repository config, including every ordered fallback and the committed branch
 * only when the trusted default branch opts into allow_repo_commands.
 *
 * A policy-enabled home registers its policy path under a private service key
 * derived from the canonical NM_HOME. Every Firstmate wrapper on the machine
 * refreshes those registrations before a guarded command. Valid registrations
 * combine conservatively: allowed-agent intersection and the smallest ceiling.
 * Thus separately configured Firstmate homes sharing one no-mistakes service
 * share one slot pool; removing a registered home policy unregisters it on the
 * next boundary. Direct operator calls that deliberately bypass Firstmate's
 * worker PATH are outside this Firstmate-owned boundary.
 *
 * Slot leases cover the complete blocking native validation call, so native
 * agent work is bounded even though non-agent steps within that call may hold
 * the slot conservatively. The native command starts behind a pipe gate whose
 * stable process identity is recorded before it can exec no-mistakes. Leases
 * carry only process identities, repository/run attribution,
 * agent identity, and stable recovery directory - never arguments, prompts, output, or
 * credentials. A dead wrapper does not free a still-live native CLI child. Once
 * both are gone, a bounded public `axi status --run` read keeps an apparently active
 * run charged and reaps a gate-returned, terminal, or absent run. Successful
 * exits release immediately. No path kills an agent or manages the shared daemon.
 *
 * Inspection:
 *   bin/no-mistakes fm-policy-status
 * prints enabled/disabled, effective agent, participant count, and active,
 * available, and ceiling counts without policy paths or invocation content.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath, URL } from "node:url";

const EXIT_POLICY = 78;
const EXIT_CAPACITY = 75;
const POLICY_FILE = "no-mistakes-policy.json";
const SCRIPT_REAL = realpathIfPresent(fileURLToPath(import.meta.url));
const SCRIPT_DIR = path.dirname(SCRIPT_REAL);
const args = process.argv.slice(2);
const statusRequested = args.length === 1 && args[0] === "fm-policy-status";
const capabilityRequested = args.length === 1 && args[0] === "fm-boundary-capability";
const guardedBoundary = classifyGuardedBoundary(args);
const guarded = guardedBoundary !== null;
let heldLease = null;
let nativeChild = null;
let relayedSignal = null;

function diagnostic(message, code = EXIT_POLICY) {
  process.stderr.write(`Firstmate no-mistakes policy: ${message}\n`);
  process.exitCode = code;
}

function realpathIfPresent(value) {
  try {
    return fs.realpathSync(value);
  } catch {
    return path.resolve(value);
  }
}

function isReadOnlyInvocation(argv) {
  const valueFlags = new Set([
    "--skip",
    "--intent",
    "--action",
    "--add-finding",
    "--findings",
    "--instructions",
    "--step",
  ]);
  let consumesNext = false;
  for (const arg of argv) {
    if (consumesNext) {
      consumesNext = false;
      continue;
    }
    if (valueFlags.has(arg)) {
      consumesNext = true;
      continue;
    }
    if (arg === "--help" || arg === "-h" || arg === "--version" || arg === "-v") return true;
  }
  return false;
}

function nextCommandToken(argv, start = 0) {
  for (let index = start; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--skip") {
      index += 1;
      continue;
    }
    if (arg.startsWith("--skip=") || arg === "--yes" || arg === "-y") continue;
    if (arg === "--") return index + 1 < argv.length ? { value: argv[index + 1], index: index + 1 } : null;
    if (arg.startsWith("-")) continue;
    return { value: arg, index };
  }
  return null;
}

function classifyGuardedBoundary(argv) {
  if (isReadOnlyInvocation(argv)) return null;
  const top = nextCommandToken(argv);
  if (!top) return null;
  if (top.value === "rerun") return "start";
  if (top.value !== "axi") return null;
  const subcommand = nextCommandToken(argv, top.index + 1);
  if (!subcommand) return null;
  if (subcommand.value === "run") return "start";
  if (subcommand.value === "respond") return "continuation";
  return null;
}

function policyHome() {
  const configured = process.env.FM_NO_MISTAKES_POLICY_HOME || process.env.FM_HOME;
  if (configured) return path.resolve(configured);
  return path.resolve(SCRIPT_DIR, "..");
}

function policyPathForHome(home) {
  return path.join(home, "config", POLICY_FILE);
}

function serviceHome() {
  return realpathIfPresent(process.env.NM_HOME || path.join(os.homedir(), ".no-mistakes"));
}

function stateRootForService(home) {
  return path.join(home, ".firstmate-policy");
}

function assertPlainDirectory(dir, create = false) {
  try {
    const st = fs.lstatSync(dir);
    if (!st.isDirectory() || st.isSymbolicLink()) {
      throw new Error(`${dir} is not a plain directory`);
    }
  } catch (error) {
    if (error?.code !== "ENOENT" || !create) throw error;
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const st = fs.lstatSync(dir);
    if (!st.isDirectory() || st.isSymbolicLink()) {
      throw new Error(`${dir} could not be created safely`);
    }
  }
  if (create) fs.chmodSync(dir, 0o700);
}

function readPolicy(file, { allowAbsent = true } = {}) {
  let st;
  try {
    st = fs.lstatSync(file);
  } catch (error) {
    if (error?.code === "ENOENT" && allowAbsent) return null;
    throw new Error(`cannot read ${file}`);
  }
  if (!st.isFile() || st.isSymbolicLink() || st.nlink !== 1) {
    throw new Error(`${file} must be a regular, non-symlinked, single-linked file`);
  }
  if (st.size > 65536) throw new Error(`${file} exceeds 65536 bytes`);
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    throw new Error(`${file} is not valid JSON (${error.message})`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${file} must contain one JSON object`);
  }
  const allowedKeys = new Set(["version", "allowedAgents", "maxConcurrent"]);
  const unknown = Object.keys(parsed).filter((key) => !allowedKeys.has(key));
  if (unknown.length) throw new Error(`${file} has unknown field ${JSON.stringify(unknown[0])}`);
  if (parsed.version !== 1) throw new Error(`${file} field version must be 1`);
  if (!Array.isArray(parsed.allowedAgents) || parsed.allowedAgents.length === 0) {
    throw new Error(`${file} field allowedAgents must be a non-empty array`);
  }
  const identities = [];
  const seen = new Set();
  for (const identity of parsed.allowedAgents) {
    if (typeof identity !== "string" || !/^[a-z][a-z0-9._-]*(?::[A-Za-z0-9._/-]+)?$/.test(identity)) {
      throw new Error(`${file} field allowedAgents contains an invalid identity`);
    }
    if (identity === "auto") {
      throw new Error(`${file} field allowedAgents cannot contain auto; list positive work-agent identities`);
    }
    if (seen.has(identity)) throw new Error(`${file} field allowedAgents contains duplicate identity ${identity}`);
    seen.add(identity);
    identities.push(identity);
  }
  if (!Number.isSafeInteger(parsed.maxConcurrent) || parsed.maxConcurrent < 1 || parsed.maxConcurrent > 256) {
    throw new Error(`${file} field maxConcurrent must be an integer from 1 through 256`);
  }
  return {
    version: 1,
    allowedAgents: identities.sort(),
    maxConcurrent: parsed.maxConcurrent,
    path: file,
  };
}

function stripYamlComment(value) {
  let single = false;
  let double = false;
  let escaped = false;
  for (let index = 0; index < value.length; index += 1) {
    const char = value[index];
    if (double && escaped) {
      escaped = false;
      continue;
    }
    if (double && char === "\\") {
      escaped = true;
      continue;
    }
    if (!double && char === "'") {
      if (single && value[index + 1] === "'") {
        index += 1;
        continue;
      }
      single = !single;
      continue;
    }
    if (!single && char === '"') {
      double = !double;
      continue;
    }
    if (!single && !double && char === "#" && (index === 0 || /\s/.test(value[index - 1]))) {
      return value.slice(0, index).trim();
    }
  }
  if (single || double || escaped) throw new Error("unterminated quoted scalar");
  return value.trim();
}

function parseYamlScalar(raw) {
  const value = stripYamlComment(raw);
  if (!value) throw new Error("agent value is empty");
  if (value.startsWith('"')) {
    try {
      const parsed = JSON.parse(value);
      if (typeof parsed !== "string") throw new Error("not a string");
      return parsed;
    } catch (error) {
      throw new Error(`agent has an invalid double-quoted value (${error.message})`);
    }
  }
  if (value.startsWith("'")) {
    if (!value.endsWith("'") || value.length < 2) throw new Error("agent has an invalid single-quoted value");
    return value.slice(1, -1).replaceAll("''", "'");
  }
  if (/\s/.test(value) || /[\[\]{},&*!|>@`]/.test(value)) {
    throw new Error("agent is not a supported plain scalar");
  }
  return value;
}

function normalizeYamlRootIndent(text, file) {
  const lines = text.split(/\r?\n/);
  let rootIndent = null;
  for (const line of lines) {
    if (/^\s*(?:#.*)?$/.test(line)) continue;
    if (/^ *\t/.test(line)) throw new Error(`${file} uses unsupported tab indentation`);
    const indent = line.match(/^ */)[0].length;
    rootIndent = rootIndent === null ? indent : Math.min(rootIndent, indent);
  }
  if (!rootIndent) return lines;
  return lines.map((line) => (/^\s*(?:#.*)?$/.test(line) ? line : line.slice(rootIndent)));
}

function readTopLevelYamlField(text, key, file) {
  const lines = normalizeYamlRootIndent(text, file);
  let found = null;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (/^\s/.test(line) || /^\s*(?:#.*)?$/.test(line)) continue;
    let single = false;
    let double = false;
    let escaped = false;
    let separator = -1;
    for (let offset = 0; offset < line.length; offset += 1) {
      const char = line[offset];
      if (double && escaped) {
        escaped = false;
        continue;
      }
      if (double && char === "\\") {
        escaped = true;
        continue;
      }
      if (!double && char === "'") {
        if (single && line[offset + 1] === "'") {
          offset += 1;
          continue;
        }
        single = !single;
        continue;
      }
      if (!single && char === '"') {
        double = !double;
        continue;
      }
      if (!single && !double && char === ":" && (offset + 1 === line.length || /\s/.test(line[offset + 1]))) {
        separator = offset;
        break;
      }
    }
    if (single || double || escaped || separator < 0) {
      throw new Error(`${file} uses an unsupported top-level YAML mapping form`);
    }
    const rawKey = line.slice(0, separator).trim();
    let decodedKey;
    if (rawKey.startsWith('"') || rawKey.startsWith("'")) {
      try {
        decodedKey = parseYamlScalar(rawKey);
      } catch (error) {
        throw new Error(`${file} has an ambiguous top-level YAML key (${error.message})`);
      }
    } else if (/^[A-Za-z_][A-Za-z0-9_-]*$/.test(rawKey)) {
      decodedKey = rawKey;
    } else {
      throw new Error(`${file} uses an unsupported top-level YAML key`);
    }
    if (decodedKey === "<<") {
      throw new Error(`${file} uses a top-level YAML merge key that cannot be resolved safely`);
    }
    if (decodedKey !== key) continue;
    if (found) throw new Error(`${file} contains duplicate top-level ${key} fields`);
    const rawValue = line.slice(separator + 1);
    const inline = stripYamlComment(rawValue);
    if (inline) {
      found = { kind: "inline", values: [rawValue] };
      continue;
    }
    const values = [];
    for (let nested = index + 1; nested < lines.length; nested += 1) {
      const line = lines[nested];
      if (/^\s*(?:#.*)?$/.test(line)) continue;
      if (/^\S/.test(line)) break;
      const item = line.match(/^\s+-\s*(.*)$/);
      if (!item) throw new Error(`${file} field ${key} uses an unsupported nested YAML form`);
      values.push(item[1]);
      index = nested;
    }
    found = { kind: "block", values };
  }
  return found;
}

function parseYamlFlowSequence(raw, file) {
  const value = stripYamlComment(raw);
  if (!value.startsWith("[")) return [parseYamlScalar(raw)];
  if (!value.endsWith("]")) throw new Error(`${file} agent has an unterminated inline list`);
  const body = value.slice(1, -1);
  const values = [];
  let start = 0;
  let single = false;
  let double = false;
  let escaped = false;
  for (let index = 0; index <= body.length; index += 1) {
    const char = body[index];
    if (index < body.length) {
      if (double && escaped) {
        escaped = false;
        continue;
      }
      if (double && char === "\\") {
        escaped = true;
        continue;
      }
      if (!double && char === "'") {
        if (single && body[index + 1] === "'") {
          index += 1;
          continue;
        }
        single = !single;
        continue;
      }
      if (!single && char === '"') {
        double = !double;
        continue;
      }
    }
    if (index === body.length || (char === "," && !single && !double)) {
      const item = body.slice(start, index).trim();
      if (!item) throw new Error(`${file} agent list contains an empty item`);
      values.push(parseYamlScalar(item));
      start = index + 1;
    }
  }
  if (single || double || escaped) throw new Error(`${file} agent list has an unterminated quoted item`);
  return values;
}

function parseAgentSelector(text, file) {
  const field = readTopLevelYamlField(text, "agent", file);
  if (!field) return null;
  let selectors;
  try {
    selectors = field.kind === "inline"
      ? parseYamlFlowSequence(field.values[0], file)
      : field.values.map((value) => parseYamlScalar(value));
  } catch (error) {
    throw new Error(`cannot determine the effective work-agent selector from ${file} (${error.message})`);
  }
  if (selectors.length === 0) throw new Error(`${file} field agent must not be an empty list`);
  for (const selector of selectors) {
    if (!/^[a-z][a-z0-9._-]*(?::[A-Za-z0-9._/-]+)?$/.test(selector)) {
      throw new Error(`${file} field agent contains invalid identity ${JSON.stringify(selector)}`);
    }
  }
  return selectors;
}

function parseBooleanField(text, key, file) {
  const field = readTopLevelYamlField(text, key, file);
  if (!field) return false;
  if (field.kind !== "inline") throw new Error(`${file} field ${key} must be true or false`);
  const value = parseYamlScalar(field.values[0]);
  if (value === "true") return true;
  if (value === "false") return false;
  throw new Error(`${file} field ${key} must be true or false`);
}

function readRegularConfigFile(file) {
  let st;
  try {
    st = fs.lstatSync(file);
  } catch {
    throw new Error(`cannot determine the effective work-agent selector because ${file} is missing`);
  }
  if (!st.isFile() || st.isSymbolicLink() || st.nlink !== 1) {
    throw new Error(`cannot determine the effective work-agent selector because ${file} is not a regular, single-linked file`);
  }
  if (st.size > 65536) throw new Error(`cannot determine the effective work-agent selector because ${file} exceeds 65536 bytes`);
  return fs.readFileSync(file, "utf8");
}

function gitResult(cwd, argv, purpose, timeout = 30000) {
  const result = spawnSync("git", argv, {
    cwd,
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    encoding: "utf8",
    timeout,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error || result.status !== 0) {
    throw new Error(`cannot determine the effective repository work-agent selector because git ${purpose} failed`);
  }
  return result.stdout;
}

function registeredRepositoryRoot(cwd) {
  let commonDir = gitResult(cwd, ["rev-parse", "--git-common-dir"], "could not resolve the registered repository root").trim();
  if (!path.isAbsolute(commonDir)) commonDir = path.resolve(cwd, commonDir);
  if (path.basename(commonDir) === ".git") return realpathIfPresent(path.dirname(commonDir));
  const worktree = spawnSync("git", ["--git-dir", commonDir, "config", "--get", "core.worktree"], {
    cwd,
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    encoding: "utf8",
    timeout: 30000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (!worktree.error && worktree.status === 0 && worktree.stdout.trim()) {
    const configured = worktree.stdout.trim();
    return realpathIfPresent(path.isAbsolute(configured) ? configured : path.resolve(commonDir, configured));
  }
  return realpathIfPresent(gitResult(cwd, ["rev-parse", "--show-toplevel"], "could not resolve the registered repository root").trim());
}

function canonicalRepositoryRemote(value, base) {
  const remote = value.trim();
  if (!remote || /[\0\r\n]/.test(remote)) throw new Error("repository remote is empty or malformed");
  if (path.isAbsolute(remote) || (!remote.includes(":") && !remote.startsWith("file://"))) {
    return `file:${realpathIfPresent(path.resolve(base, remote))}`;
  }
  if (remote.startsWith("file://")) {
    const parsed = new URL(remote);
    if (parsed.search || parsed.hash) throw new Error("repository file remote has unsupported components");
    return `file:${realpathIfPresent(fileURLToPath(parsed))}`;
  }
  let host;
  let remotePath;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(remote)) {
    const parsed = new URL(remote);
    if (!parsed.hostname || parsed.search || parsed.hash) throw new Error("repository remote has unsupported components");
    host = parsed.host;
    remotePath = parsed.pathname;
  } else {
    const scp = remote.match(/^(?:[^/@:\s]+@)?([^/:\s]+):(.+)$/);
    if (!scp) throw new Error("repository remote is unsupported");
    host = scp[1];
    remotePath = scp[2];
  }
  remotePath = remotePath.replace(/^\/+|\/+$/g, "").replace(/\.git$/i, "");
  if (!remotePath) throw new Error("repository remote has no repository path");
  return `remote:${host.toLowerCase()}/${remotePath}`;
}

function registeredRepositoryRows(database) {
  return database.prepare("SELECT id, working_path, upstream_url, default_branch FROM repos").all();
}

async function openStateDatabase(nmHome) {
  const databaseFile = path.join(nmHome, "state.sqlite");
  const originalEmitWarning = process.emitWarning;
  process.emitWarning = (warning, options, ...rest) => {
    const type = typeof options === "string" ? options : options?.type;
    if (type === "ExperimentalWarning" && String(warning).includes("SQLite")) return;
    originalEmitWarning.call(process, warning, options, ...rest);
  };
  let sqlite;
  try {
    sqlite = await import("node:sqlite");
  } catch (error) {
    throw new Error(`cannot determine the effective repository work-agent selector because ${databaseFile} cannot be read with this Node runtime (${error.message})`);
  } finally {
    process.emitWarning = originalEmitWarning;
  }
  try {
    return new sqlite.DatabaseSync(databaseFile, { readOnly: true });
  } catch (error) {
    throw new Error(`cannot read registered no-mistakes metadata from ${databaseFile} (${error.message})`);
  }
}

async function readRegisteredRepository(nmHome, cwd) {
  const repositoryRoot = registeredRepositoryRoot(cwd);
  let database;
  try {
    database = await openStateDatabase(nmHome);
    let rows = database.prepare("SELECT id, working_path, upstream_url, default_branch FROM repos WHERE working_path = ?").all(repositoryRoot);
    if (rows.length === 0) {
      const configured = gitResult(cwd, ["config", "--null", "--get-all", "remote.origin.url"], "could not resolve the repository origin");
      const remotes = configured.split("\0").filter(Boolean);
      if (remotes.length !== 1) throw new Error(`no unique repository origin identifies ${repositoryRoot}`);
      const resolved = gitResult(cwd, ["remote", "get-url", "origin"], "could not resolve the effective repository origin").trim();
      const identities = new Set([
        canonicalRepositoryRemote(remotes[0], repositoryRoot),
        canonicalRepositoryRemote(resolved, repositoryRoot),
      ]);
      rows = registeredRepositoryRows(database).filter((row) => {
        try {
          return identities.has(canonicalRepositoryRemote(row.upstream_url, row.working_path));
        } catch {
          return false;
        }
      });
    }
    if (rows.length !== 1 || typeof rows[0].default_branch !== "string" || !rows[0].default_branch.trim()) {
      throw new Error(`no unique registered repository matches ${repositoryRoot}`);
    }
    return {
      id: rows[0].id,
      workingPath: realpathIfPresent(rows[0].working_path),
      defaultBranch: rows[0].default_branch.trim(),
    };
  } catch (error) {
    throw new Error(`cannot determine the effective repository work-agent selector from registered no-mistakes metadata (${error.message})`);
  } finally {
    database?.close();
  }
}

function readRepositoryConfigAtCommit(top, commit, label) {
  const row = gitResult(top, ["ls-tree", commit, "--", ".no-mistakes.yaml"], `could not inspect ${label}`);
  if (!row.trim()) return null;
  const mode = row.trim().split(/\s+/, 1)[0];
  if (mode !== "100644" && mode !== "100755") {
    throw new Error(`cannot determine the effective repository work-agent selector because ${label} .no-mistakes.yaml is not a regular file`);
  }
  const text = gitResult(top, ["show", `${commit}:.no-mistakes.yaml`], `could not read ${label}`);
  if (Buffer.byteLength(text) > 65536) {
    throw new Error(`cannot determine the effective repository work-agent selector because ${label} .no-mistakes.yaml exceeds 65536 bytes`);
  }
  return text;
}

async function readEffectiveRepositorySelector(nmHome, cwd) {
  const top = gitResult(cwd, ["rev-parse", "--show-toplevel"], "could not resolve the repository").trim();
  const repository = await readRegisteredRepository(nmHome, cwd);
  const defaultBranch = repository.defaultBranch;
  const trustedRef = `refs/heads/${defaultBranch}`;
  gitResult(top, ["check-ref-format", trustedRef], "registered default branch is invalid");
  let trustedOid = null;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const before = gitResult(top, ["ls-remote", "origin", trustedRef], "could not resolve the registered default branch", 15000);
    const oidMatch = before.match(new RegExp(`^([0-9a-f]{40,64})\\s+${trustedRef.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m"));
    if (!oidMatch) throw new Error(`cannot determine the effective repository work-agent selector because origin has no readable registered default branch ${JSON.stringify(defaultBranch)}`);
    trustedOid = oidMatch[1];
    gitResult(top, ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "origin", trustedRef], "could not fetch origin's live default branch", 60000);
    const after = gitResult(top, ["ls-remote", "origin", trustedRef], "could not re-check the registered default branch", 15000);
    const afterOid = after.match(new RegExp(`^([0-9a-f]{40,64})\\s+${trustedRef.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "m"))?.[1];
    if (afterOid === trustedOid) break;
    trustedOid = null;
  }
  if (!trustedOid) {
    throw new Error("cannot determine the effective repository work-agent selector because the registered default branch changed during preflight; retry");
  }
  gitResult(top, ["cat-file", "-e", `${trustedOid}^{commit}`], "could not verify the registered default commit");
  const trustedLabel = `origin/${defaultBranch}`;
  const trustedConfig = readRepositoryConfigAtCommit(top, trustedOid, trustedLabel);
  const allowBranchConfig = trustedConfig
    ? parseBooleanField(trustedConfig, "allow_repo_commands", `${trustedLabel}:.no-mistakes.yaml`)
    : false;
  let selectedConfig = trustedConfig;
  let selectedLabel = `${trustedLabel}:.no-mistakes.yaml`;
  if (allowBranchConfig) {
    const head = gitResult(top, ["rev-parse", "HEAD"], "could not resolve the current branch head").trim();
    selectedConfig = readRepositoryConfigAtCommit(top, head, "HEAD");
    selectedLabel = "HEAD:.no-mistakes.yaml";
  }
  const branch = gitResult(top, ["symbolic-ref", "--quiet", "--short", "HEAD"], "could not resolve the current branch").trim();
  const head = gitResult(top, ["rev-parse", "HEAD"], "could not resolve the current branch head").trim();
  return {
    selectors: selectedConfig ? parseAgentSelector(selectedConfig, selectedLabel) : null,
    repository: { ...repository, branch, head },
  };
}

async function readEffectiveAgentSelector(nmHome) {
  const resolved = await readEffectiveRepositorySelector(nmHome, process.cwd());
  const globalFile = path.join(nmHome, "config.yaml");
  const globalText = readRegularConfigFile(globalFile);
  const globalSelector = parseAgentSelector(globalText, globalFile) || ["auto"];
  return {
    selectors: resolved.selectors || globalSelector,
    repository: resolved.repository,
  };
}

async function readActiveRuns(nmHome) {
  let database;
  try {
    database = await openStateDatabase(nmHome);
    return database.prepare(
      "SELECT id, repo_id, branch, head_sha, status FROM runs WHERE status IN ('pending', 'running') ORDER BY created_at DESC, id DESC",
    ).all().map((row) => ({
      id: row.id,
      repositoryId: row.repo_id,
      branch: row.branch,
      head: row.head_sha,
      status: row.status,
    }));
  } catch (error) {
    throw new Error(`cannot determine active no-mistakes runs (${error.message})`);
  } finally {
    database?.close();
  }
}

function nativePath() {
  const inherited = process.env.FM_NO_MISTAKES_NATIVE_BIN;
  if (inherited) {
    const candidate = path.resolve(inherited);
    const st = fs.statSync(candidate);
    if (!st.isFile() || (st.mode & 0o111) === 0 || realpathIfPresent(candidate) === SCRIPT_REAL) {
      throw new Error("FM_NO_MISTAKES_NATIVE_BIN does not name an executable native no-mistakes binary");
    }
    return candidate;
  }
  const search = (process.env.PATH || "").split(path.delimiter);
  for (const dir of search) {
    if (!dir) continue;
    const candidate = path.join(dir, "no-mistakes");
    try {
      const st = fs.statSync(candidate);
      if (st.isFile() && (st.mode & 0o111) !== 0 && realpathIfPresent(candidate) !== SCRIPT_REAL) return candidate;
    } catch {
      // Continue through PATH.
    }
  }
  throw new Error("native no-mistakes binary is unavailable; launch workers through bin/fm-spawn.sh or set FM_NO_MISTAKES_NATIVE_BIN");
}

function nativeEnvironment() {
  const env = { ...process.env };
  env.PATH = (env.PATH || "").split(path.delimiter).filter((entry) => realpathIfPresent(entry) !== SCRIPT_DIR).join(path.delimiter);
  delete env.FM_NO_MISTAKES_NATIVE_PATH;
  return env;
}

function processIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid < 2) return null;
  try {
    process.kill(pid, 0);
  } catch (error) {
    if (error?.code === "EPERM") {
      // Continue to ps; the process exists but is not ours.
    } else {
      return null;
    }
  }
  const result = spawnSync("ps", ["-p", String(pid), "-o", "lstart="], {
    encoding: "utf8",
    timeout: 2000,
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) return null;
  const identity = result.stdout.trim();
  return identity || null;
}

function pidExists(pid) {
  if (!Number.isSafeInteger(pid) || pid < 2) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function processMatches(pid, identity) {
  if (!identity || !pidExists(pid)) return false;
  const observed = processIdentity(pid);
  return observed === null || observed === identity;
}

function atomicJson(file, value) {
  const dir = path.dirname(file);
  const temp = path.join(dir, `.${path.basename(file)}.${process.pid}.${crypto.randomUUID()}.tmp`);
  fs.writeFileSync(temp, `${JSON.stringify(value)}\n`, { mode: 0o600, flag: "wx" });
  fs.renameSync(temp, file);
  fs.chmodSync(file, 0o600);
}

function readJsonFile(file) {
  const st = fs.lstatSync(file);
  if (!st.isFile() || st.isSymbolicLink()) throw new Error("not a regular file");
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

async function sleep(milliseconds) {
  await new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function signalExitCode(signal) {
  return 128 + (os.constants.signals[signal] || 1);
}

function throwIfInterrupted() {
  if (!relayedSignal) return;
  const error = new Error(`interrupted by ${relayedSignal}`);
  error.interrupted = true;
  throw error;
}

async function acquireLock(root) {
  const lock = path.join(root, ".lock");
  const token = crypto.randomUUID();
  const ownerStart = processIdentity(process.pid);
  if (!ownerStart) throw new Error("cannot establish this wrapper process identity for machine-shared accounting");
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    throwIfInterrupted();
    try {
      fs.mkdirSync(lock, { mode: 0o700 });
      atomicJson(path.join(lock, "owner.json"), {
        version: 1,
        token,
        pid: process.pid,
        processStart: ownerStart,
        createdAt: new Date().toISOString(),
      });
      return { lock, token };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
    let owner = null;
    let age = 0;
    try {
      owner = readJsonFile(path.join(lock, "owner.json"));
      age = Date.now() - fs.statSync(lock).mtimeMs;
    } catch {
      try {
        age = Date.now() - fs.statSync(lock).mtimeMs;
      } catch {
        age = 0;
      }
    }
    if (owner && processMatches(owner.pid, owner.processStart)) {
      await sleep(25);
      throwIfInterrupted();
      continue;
    }
    if (age < 2000) {
      await sleep(25);
      throwIfInterrupted();
      continue;
    }
    const stale = `${lock}.stale.${process.pid}.${crypto.randomUUID()}`;
    try {
      fs.renameSync(lock, stale);
      fs.rmSync(stale, { recursive: true, force: true });
    } catch {
      await sleep(25);
      throwIfInterrupted();
    }
  }
  throw new Error("could not acquire the machine-shared policy lock within 5 seconds");
}

function releaseLock(owner) {
  if (!owner) return;
  try {
    const current = readJsonFile(path.join(owner.lock, "owner.json"));
    if (current.token !== owner.token || current.pid !== process.pid) return;
    fs.rmSync(owner.lock, { recursive: true, force: true });
  } catch {
    // A contender can recover an abandoned lock. Never remove an unverified one.
  }
}

async function withLock(root, callback) {
  const owner = await acquireLock(root);
  try {
    return await callback();
  } finally {
    releaseLock(owner);
  }
}

function participantRecordPath(root, policyPath) {
  const digest = crypto.createHash("sha256").update(path.resolve(policyPath)).digest("hex");
  return path.join(root, "participants", `${digest}.json`);
}

function registerCurrentPolicy(root, currentPath, currentPolicy) {
  const participantsDir = path.join(root, "participants");
  assertPlainDirectory(participantsDir, true);
  const record = participantRecordPath(root, currentPath);
  if (!currentPolicy) {
    fs.rmSync(record, { force: true });
    return;
  }
  atomicJson(record, { version: 1, policyPath: path.resolve(currentPath) });
}

function effectiveRegisteredPolicy(root) {
  const participantsDir = path.join(root, "participants");
  assertPlainDirectory(participantsDir, true);
  const policies = [];
  for (const entry of fs.readdirSync(participantsDir).sort()) {
    if (!entry.endsWith(".json")) continue;
    const recordPath = path.join(participantsDir, entry);
    let record;
    try {
      record = readJsonFile(recordPath);
      if (record.version !== 1 || typeof record.policyPath !== "string" || !path.isAbsolute(record.policyPath)) {
        throw new Error("invalid registration");
      }
    } catch {
      fs.rmSync(recordPath, { force: true });
      continue;
    }
    let policy;
    try {
      policy = readPolicy(record.policyPath);
    } catch (error) {
      throw new Error(`registered ${POLICY_FILE} is invalid (${error.message}); fix or remove it to disable that home policy`);
    }
    if (!policy) {
      fs.rmSync(recordPath, { force: true });
      continue;
    }
    policies.push(policy);
  }
  if (policies.length === 0) return null;
  let allowed = new Set(policies[0].allowedAgents);
  let ceiling = policies[0].maxConcurrent;
  for (const policy of policies.slice(1)) {
    allowed = new Set([...allowed].filter((identity) => policy.allowedAgents.includes(identity)));
    ceiling = Math.min(ceiling, policy.maxConcurrent);
  }
  return {
    allowedAgents: [...allowed].sort(),
    maxConcurrent: ceiling,
    participants: policies.length,
  };
}

function leaseDir(root) {
  const dir = path.join(root, "leases");
  assertPlainDirectory(dir, true);
  return dir;
}

function bindingDir(root) {
  const dir = path.join(root, "run-bindings");
  assertPlainDirectory(dir, true);
  return dir;
}

function bindingPath(root, runId) {
  const digest = crypto.createHash("sha256").update(runId).digest("hex");
  return path.join(bindingDir(root), `${digest}.json`);
}

function readRunBinding(root, runId) {
  try {
    const binding = readJsonFile(bindingPath(root, runId));
    if (binding.version !== 1 || binding.runId !== runId || !Array.isArray(binding.selectors)) {
      throw new Error("invalid binding");
    }
    return binding;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new Error(`cannot read the validation run's starting selector (${error.message})`);
  }
}

function writeRunBinding(root, run, repository, selectors) {
  atomicJson(bindingPath(root, run.id), {
    version: 1,
    runId: run.id,
    repositoryId: repository.id,
    branch: repository.branch,
    head: run.head,
    selectors,
    createdAt: new Date().toISOString(),
  });
}

function statusLooksQuiescent(output) {
  if (/no active run/i.test(output)) return true;
  if (/^outcome:\s*\S+/m.test(output)) return true;
  if (/^\s*status:\s*(?:completed|failed|cancelled|awaiting_approval)\s*$/m.test(output)) return true;
  if (/^\s*awaiting_agent:\s*parked\b/m.test(output)) return true;
  if (/^gate:\s*\S+/m.test(output)) return true;
  if (/^gate:\s*$/m.test(output)) return true;
  return false;
}

function staleLeaseQuiescent(lease, native, env, activeRuns, nmHome) {
  if (!lease.nativePid) {
    const created = Date.parse(lease.createdAt);
    if (!Number.isFinite(created) || Date.now() - created < 5000) return false;
  }
  let runId = typeof lease.runId === "string" && lease.runId ? lease.runId : null;
  if (!runId && typeof lease.repositoryId === "string" && typeof lease.branch === "string") {
    const matches = activeRuns.filter((run) => run.repositoryId === lease.repositoryId && run.branch === lease.branch);
    if (matches.length > 1) return false;
    if (matches.length === 1) runId = matches[0].id;
    else return true;
  }
  if (!runId) return false;
  const stillActive = activeRuns.some((run) => run.id === runId);
  if (!stillActive) return true;
  let cwd = typeof lease.stableCwd === "string" && path.isAbsolute(lease.stableCwd) ? lease.stableCwd : nmHome;
  try {
    if (!fs.statSync(cwd).isDirectory()) cwd = nmHome;
  } catch {
    cwd = nmHome;
  }
  const result = spawnSync(native, ["axi", "status", "--run", runId], {
    cwd,
    env: { ...env, NO_MISTAKES_NO_UPDATE_CHECK: "1" },
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  return statusLooksQuiescent(output);
}

function activeLeases(root, native, env, activeRuns, nmHome) {
  const dir = leaseDir(root);
  const active = [];
  for (const entry of fs.readdirSync(dir).sort()) {
    if (!entry.endsWith(".json")) continue;
    const file = path.join(dir, entry);
    let lease;
    try {
      lease = readJsonFile(file);
      if (lease.version !== 1 || typeof lease.token !== "string" || typeof lease.createdAt !== "string") {
        throw new Error("invalid lease");
      }
    } catch {
      fs.rmSync(file, { force: true });
      continue;
    }
    const holderAlive = processMatches(lease.holderPid, lease.holderStart);
    const nativeAlive = processMatches(lease.nativePid, lease.nativeStart);
    if (holderAlive || nativeAlive) {
      active.push({ ...lease, file });
      continue;
    }
    if (!staleLeaseQuiescent(lease, native, env, activeRuns, nmHome)) {
      active.push({ ...lease, file });
      continue;
    }
    fs.rmSync(file, { force: true });
  }
  return active;
}

async function readBoundaryState({ acquire = false } = {}) {
  const home = policyHome();
  const currentPath = policyPathForHome(home);
  let currentPolicy;
  try {
    currentPolicy = readPolicy(currentPath);
  } catch (error) {
    throw new Error(`${error.message}; fix or remove it to disable the policy`);
  }
  const nmHome = serviceHome();
  const root = stateRootForService(nmHome);
  const rootExists = fs.existsSync(root);
  if (!currentPolicy && !rootExists) {
    return { policy: null, nmHome, root, selectors: [], agent: null, active: 0, available: null, lease: null };
  }
  assertPlainDirectory(root, true);
  const native = nativePath();
  const env = nativeEnvironment();
  const initialPolicy = await withLock(root, async () => {
    registerCurrentPolicy(root, currentPath, currentPolicy);
    return effectiveRegisteredPolicy(root);
  });
  if (!initialPolicy) {
    return { policy: null, nmHome, root, native, env, selectors: [], agent: null, active: 0, available: null, lease: null };
  }

  // Repository selector resolution can perform bounded network reads. Keep it
  // outside the machine-shared accounting lock so simultaneous cohort members
  // preflight in parallel and serialize only the final policy/slot mutation.
  const resolved = await readEffectiveAgentSelector(nmHome);
  const selectors = resolved.selectors;
  const repository = resolved.repository;
  const activeRuns = await readActiveRuns(nmHome);
  const matchingRuns = activeRuns.filter((run) => run.repositoryId === repository.id && run.branch === repository.branch);
  if (matchingRuns.length > 1) {
    throw new Error(`cannot bind validation policy because multiple active runs match repository ${repository.id} branch ${repository.branch}`);
  }
  const currentRun = matchingRuns[0] || null;
  const agent = selectors.join(",");
  return withLock(root, async () => {
    registerCurrentPolicy(root, currentPath, currentPolicy);
    const policy = effectiveRegisteredPolicy(root);
    if (!policy) {
      return { policy: null, nmHome, root, native, env, selectors: [], agent: null, active: 0, available: null, lease: null };
    }
    const leases = activeLeases(root, native, env, activeRuns, nmHome);
    const active = leases.length;
    const available = Math.max(0, policy.maxConcurrent - active);
    if (!acquire) return { policy, nmHome, root, native, env, selectors, agent, active, available, lease: null };
    let authorizedSelectors = selectors;
    if (currentRun) {
      let binding = readRunBinding(root, currentRun.id);
      if (!binding) {
        const candidates = leases.filter((lease) => lease.repositoryId === repository.id && lease.branch === repository.branch);
        const selectorSets = new Map(candidates.filter((lease) => Array.isArray(lease.selectors)).map((lease) => [JSON.stringify(lease.selectors), lease.selectors]));
        if (selectorSets.size !== 1) {
          throw new Error(`cannot continue active run ${currentRun.id} because its starting work-agent selector is not attributable to this boundary`);
        }
        const pinned = [...selectorSets.values()][0];
        writeRunBinding(root, currentRun, repository, pinned);
        binding = readRunBinding(root, currentRun.id);
      }
      if (binding.repositoryId !== repository.id || binding.branch !== repository.branch || binding.head !== currentRun.head) {
        throw new Error(`cannot continue active run ${currentRun.id} because its starting selector binding does not match the active run`);
      }
      if (JSON.stringify(binding.selectors) !== JSON.stringify(selectors)) {
        throw new Error(`denied selector drift for active run ${currentRun.id}: started with ${JSON.stringify(binding.selectors)} but current effective selector is ${JSON.stringify(selectors)}`);
      }
      authorizedSelectors = binding.selectors;
    } else if (guardedBoundary === "continuation") {
      throw new Error("cannot continue validation because no attributable active run exists for this repository branch");
    }
    const denied = authorizedSelectors.filter((identity) => !policy.allowedAgents.includes(identity));
    if (denied.length > 0) {
      const allowed = policy.allowedAgents.length ? policy.allowedAgents.join(",") : "none (configured policy intersections do not overlap)";
      if (authorizedSelectors.length === 1) {
        throw new Error(`denied effective agent ${JSON.stringify(denied[0])}; allowed identities: ${allowed}. Configure an allowed explicit global or repository selector and retry`);
      }
      throw new Error(`denied effective selector ${JSON.stringify(authorizedSelectors)}; disallowed fallback identities: ${denied.join(",")}; allowed identities: ${allowed}. Configure only allowed explicit global or repository selectors and retry`);
    }
    if (active >= policy.maxConcurrent) {
      const capacity = new Error(`capacity reached: agent=${agent} active=${active} available=0 ceiling=${policy.maxConcurrent}; retry after another validation boundary returns`);
      capacity.exitCode = EXIT_CAPACITY;
      throw capacity;
    }
    const token = crypto.randomUUID();
    const file = path.join(leaseDir(root), `${token}.json`);
    const holderStart = processIdentity(process.pid);
    if (!holderStart) throw new Error("cannot establish this wrapper process identity for slot recovery");
    const lease = {
      version: 1,
      token,
      holderPid: process.pid,
      holderStart,
      nativePid: null,
      nativeStart: null,
      handoff: "reserved",
      cwd: path.resolve(process.cwd()),
      stableCwd: repository.workingPath,
      repositoryId: repository.id,
      branch: repository.branch,
      head: repository.head,
      runId: currentRun?.id || null,
      selectors: authorizedSelectors,
      agent,
      createdAt: new Date().toISOString(),
    };
    atomicJson(file, lease);
    return {
      policy,
      nmHome,
      root,
      native,
      env,
      selectors,
      repository,
      agent,
      active: active + 1,
      available: Math.max(0, policy.maxConcurrent - active - 1),
      lease: { ...lease, file },
    };
  });
}

function refreshLeaseNative(lease, pid) {
  if (!lease) return;
  const nativeStart = processIdentity(pid);
  if (!nativeStart) throw new Error("cannot establish the native command process identity for slot recovery");
  let current;
  try {
    current = readJsonFile(lease.file);
  } catch {
    throw new Error("the acquired validation slot disappeared before native launch");
  }
  if (current.token !== lease.token || current.holderPid !== process.pid) {
    throw new Error("the acquired validation slot changed owner before native launch");
  }
  current.nativePid = pid;
  current.nativeStart = nativeStart;
  current.handoff = "durable";
  atomicJson(lease.file, current);
  Object.assign(lease, current);
}

async function captureLeaseRun(state) {
  if (!state.lease || state.lease.runId) return;
  let run = null;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const runs = await readActiveRuns(state.nmHome);
    const matches = runs.filter((candidate) => candidate.repositoryId === state.repository.id && candidate.branch === state.repository.branch);
    if (matches.length > 1) throw new Error("multiple active runs appeared while binding the validation selector");
    if (matches.length === 1) {
      run = matches[0];
      break;
    }
    if (nativeChild?.exitCode !== null || nativeChild?.signalCode) break;
    await sleep(20);
  }
  if (!run) return;
  await withLock(state.root, async () => {
    const current = readJsonFile(state.lease.file);
    if (current.token !== state.lease.token) throw new Error("the acquired validation slot changed owner during run binding");
    current.runId = run.id;
    atomicJson(state.lease.file, current);
    Object.assign(state.lease, current);
    writeRunBinding(state.root, run, state.repository, state.lease.selectors);
  });
}

async function releaseLease(lease) {
  if (!lease) return;
  try {
    const current = readJsonFile(lease.file);
    if (current.token === lease.token) fs.rmSync(lease.file, { force: true });
  } catch {
    // Already recovered or absent. A unique token makes direct removal safe
    // even while an interrupted wrapper cannot re-enter the shared scan lock.
  }
}

async function inspectStatus() {
  let state;
  try {
    state = await readBoundaryState({ acquire: false });
  } catch (error) {
    diagnostic(`invalid: ${error.message}`);
    return;
  }
  if (!state.policy) {
    process.stdout.write("policy=disabled active=0 available=unbounded ceiling=unbounded participants=0\n");
    return;
  }
  const allowed = state.selectors.every((identity) => state.policy.allowedAgents.includes(identity));
  process.stdout.write(
    `policy=enabled agent=${state.agent} allowed=${allowed ? "true" : "false"} active=${state.active} available=${state.available} ceiling=${state.policy.maxConcurrent} participants=${state.policy.participants}\n`,
  );
}

function observeChild(child) {
  const spawned = new Promise((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  const exited = new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal, error: null }));
    child.once("error", (error) => resolve({ code: null, signal: null, error }));
  });
  return { spawned, exited };
}

function spawnNativeBehindGate(native, argv, env) {
  const gate = 'IFS= read -r fm_launch_token && [ "$fm_launch_token" = launch ] || exit 125\nexec "$@"';
  const child = spawn("/bin/sh", ["-c", gate, "fm-no-mistakes-native-gate", native, ...argv], {
    stdio: ["pipe", "inherit", "inherit"],
    env,
  });
  child.stdin.on("error", () => {
    // Exit observation owns an interrupted or failed gate write.
  });
  return child;
}

async function invokeNativeWithoutPolicy() {
  let native;
  try {
    throwIfInterrupted();
    native = nativePath();
    throwIfInterrupted();
  } catch (error) {
    if (error.interrupted) {
      process.exitCode = signalExitCode(relayedSignal);
    } else {
      diagnostic(error.message);
    }
    return;
  }
  try {
    nativeChild = spawn(native, args, { stdio: "inherit", env: nativeEnvironment() });
    const observed = observeChild(nativeChild);
    await observed.spawned;
    const outcome = await observed.exited;
    nativeChild = null;
    if (outcome.error) throw outcome.error;
    process.exitCode = outcome.code ?? signalExitCode(outcome.signal);
  } catch (error) {
    nativeChild = null;
    if (relayedSignal) process.exitCode = signalExitCode(relayedSignal);
    else diagnostic(`could not launch native no-mistakes (${error.message})`);
  }
}

async function invokeGuarded() {
  let state;
  try {
    state = await readBoundaryState({ acquire: true });
  } catch (error) {
    if (error.interrupted) process.exitCode = signalExitCode(relayedSignal);
    else diagnostic(error.message, error.exitCode || EXIT_POLICY);
    return;
  }
  if (!state.policy) {
    await invokeNativeWithoutPolicy();
    return;
  }
  heldLease = state.lease;
  process.stderr.write(
    `Firstmate no-mistakes policy: agent=${state.agent} active=${state.active} available=${state.available} ceiling=${state.policy.maxConcurrent}; slot acquired.\n`,
  );
  let observed = null;
  let nativeLaunched = false;
  try {
    throwIfInterrupted();
    nativeChild = spawnNativeBehindGate(state.native, args, state.env);
    observed = observeChild(nativeChild);
    await observed.spawned;
    refreshLeaseNative(heldLease, nativeChild.pid);
    // processIdentity uses a bounded synchronous ps read. Yield once before
    // opening the pipe gate so a signal delivered during that read becomes an
    // observed interruption rather than a native launch race.
    await new Promise((resolve) => setImmediate(resolve));
    throwIfInterrupted();
    nativeLaunched = true;
    nativeChild.stdin.end("launch\n");
    await captureLeaseRun(state);
    const outcome = await observed.exited;
    if (outcome.error) throw outcome.error;
    nativeChild = null;
    if (relayedSignal || outcome.signal || outcome.code !== 0) {
      heldLease = null;
      process.exitCode = relayedSignal
        ? signalExitCode(relayedSignal)
        : outcome.signal
          ? signalExitCode(outcome.signal)
          : outcome.code;
      return;
    }
    await releaseLease(heldLease);
    heldLease = null;
    process.exitCode = outcome.code ?? signalExitCode(outcome.signal);
  } catch (error) {
    if (nativeChild) {
      try {
        nativeChild.stdin.end();
      } catch {
        // The exact child may already have consumed or closed the gate.
      }
      if (nativeChild.pid && pidExists(nativeChild.pid)) {
        try {
          nativeChild.kill(relayedSignal || "SIGTERM");
        } catch {
          // Exact child exit observation below remains authoritative.
        }
      }
      if (observed) await observed.exited;
      nativeChild = null;
    }
    if (nativeLaunched) {
      heldLease = null;
    } else {
      await releaseLease(heldLease);
      heldLease = null;
    }
    if (relayedSignal || error.interrupted) process.exitCode = signalExitCode(relayedSignal);
    else diagnostic(`native launch failed (${error.message})`);
  }
}

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    relayedSignal = relayedSignal || signal;
    if (nativeChild?.pid) {
      try {
        nativeChild.kill(signal);
      } catch {
        // Child outcome or stale-lease recovery owns the result.
      }
    } else {
      process.exitCode = signalExitCode(signal);
    }
  });
}

if (capabilityRequested) process.stdout.write("firstmate-no-mistakes-boundary-v1\n");
else if (statusRequested) await inspectStatus();
else if (guarded) await invokeGuarded();
else await invokeNativeWithoutPolicy();

if (relayedSignal) process.exitCode = signalExitCode(relayedSignal);
