#!/usr/bin/env python3
# Emit the one tracked AGENT-CONTEXT block for a repository's AGENTS.md.
#
# Contract owner: this executable and its --help own the complete format,
# marker, migration, validation, measurement, redaction, and drift contract.
# `emit` writes exactly one <!-- AGENT-CONTEXT:BEGIN --> through
# <!-- AGENT-CONTEXT:END --> envelope. It replaces only that envelope and
# preserves every byte of prose outside it. The envelope contains two inputs:
# optional domain facts from a validated context.yaml/context.schema.json pair,
# and repository shape measured from Git and declared source manifests.
# Rendered input escapes HTML comment openers so values cannot introduce current
# or legacy markers; the complete candidate is checked before writing.
#
# A context.yaml is optional. If present, context.schema.json must also be
# present. The dependency-free schema subset listed in --help is enforced,
# and unsupported or malformed constraints are refused throughout the schema,
# including absent properties, before applying the satellite semantic checks.
# If context.yaml is absent, the envelope states that no domain contract is
# configured, so ordinary repositories remain supported.
#
# `check` is compare-only and exits nonzero for a missing, malformed, legacy,
# duplicate, or drifting envelope. It never writes. Stored shape deliberately
# excludes volatile HEAD, dirty count, ahead/behind, and graph freshness.
#
# Legacy DOMAIN SPECIALIZATION and GROUND-TRUTH pairs are never silently
# rewritten. `emit --migrate-legacy` performs one guarded migration only when
# there is no AGENT-CONTEXT envelope and each legacy pair is complete and unique.
# It removes either or both legacy generated regions, preserves all other prose,
# and writes the one current envelope. A later run cannot migrate again.
#
# Remote URLs are redacted while being measured: any URL userinfo is replaced
# before rendering, so credentials cannot reach AGENTS.md. The inherited domain
# schema remains fixed to primary plus secondary_sandbox tenants. A third tenant
# still requires a schema and renderer migration, unchanged from that contract.
#
# This is a standalone utility, not wired into automatic project initialization
# or fleet sync. It neither invokes nor deletes home-local legacy writers.
# Regression and deliberate-mutation coverage lives in tests/fm-agent-context.test.sh;
# its guarded migration cases operate only on disposable repository copies.
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

BEGIN = b"<!-- AGENT-CONTEXT:BEGIN -->"
END = b"<!-- AGENT-CONTEXT:END -->"
DOMAIN_BEGIN = b"<!-- DOMAIN SPECIALIZATION:BEGIN -->"
DOMAIN_END = b"<!-- DOMAIN SPECIALIZATION:END -->"
DOMAIN_HEADING = b"## DOMAIN SPECIALIZATION (generated from context.yaml \xe2\x80\x94 do not hand-edit)\n\n"
GROUND_BEGIN = re.compile(rb"<!-- GROUND-TRUTH:BEGIN(?:[^>]*)-->")
GROUND_END = b"<!-- GROUND-TRUTH:END -->"
VALIDATED_STATES = {"validated", "signed", "injected"}
BUILT_IN_MCP_TOOL = "get_satellite_status"


class ContractError(Exception):
    """A malformed input or an unmet AGENT-CONTEXT contract."""


def usage() -> str:
    return """usage: fm-agent-context.py {emit|check} [--repo DIR] [--context PATH] [--schema PATH] [--migrate-legacy]

Emit or compare the one generated AGENT-CONTEXT envelope in DIR/AGENTS.md.

Format
  The only generated markers are:
    <!-- AGENT-CONTEXT:BEGIN -->
    <!-- AGENT-CONTEXT:END -->
  Exactly one complete pair is valid. emit replaces only that byte range and
  leaves prose before and after it untouched. It creates AGENTS.md when absent.

Inputs
  Repository shape is measured from Git, graphify-out/graph.json, package.json,
  Makefile, pyproject.toml, executable bin/ entries, and conventional docs.
  Stable shape is stored; volatile HEAD, dirty count, upstream divergence, and
  graph freshness are intentionally omitted. context.yaml is optional. When it
  exists, context.schema.json is required and validated strictly, followed by
  the satellite semantic checks, before its domain facts are rendered.
  The dependency-free schema subset supports type, enum, minLength, minimum,
  maximum, minItems, items (object schema), required, properties, and boolean
  additionalProperties. Draft-07 declarations and title/description annotations
  are accepted. Unsupported keywords or malformed schemas are refused in full,
  including constraints on absent properties, before writing.

Modes
  emit   write the expected envelope if needed.
  check  compare only; exits nonzero for missing, malformed, legacy, duplicate,
         or different generated content and never writes.

Legacy migration
  DOMAIN SPECIALIZATION and GROUND-TRUTH markers are refused normally. Use
  emit --migrate-legacy only for a deliberate one-time conversion. Migration
  requires no current AGENT-CONTEXT pair and exactly one complete pair for each
  legacy type present; it can convert either legacy type or both together.
  It removes only their generated regions, preserves surrounding prose, and
  emits one current envelope. It never runs during check or ordinary emit.

Redaction
  Origin URLs are redacted while measured. URL userinfo, including a synthetic
  user:token@host authority, becomes <redacted>@host before rendering.

Tenant scope
  The inherited satellite schema remains fixed to primary plus secondary_sandbox.
  Adding a third tenant still needs a schema and renderer migration, so this
  merged emitter makes that change unchanged in cost from today's contract.
"""


def parse_yaml_file(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if text.lstrip().startswith("{"):
        value = json.loads(text)
    else:
        value = _YamlParser(text).parse()
    if not isinstance(value, dict):
        raise ContractError("context root must be an object")
    return value


class _YamlParser:
    """The dependency-free YAML subset used by existing satellite context files."""

    def __init__(self, text: str) -> None:
        self.lines = [
            (len(raw) - len(raw.lstrip(" ")), raw.strip())
            for raw in text.splitlines()
            if raw.strip() and not raw.lstrip().startswith("#")
        ]

    def parse(self) -> Any:
        if not self.lines:
            return {}
        value, index = self._parse_block(0, self.lines[0][0])
        if index != len(self.lines):
            raise ContractError(f"unexpected YAML content near line {index + 1}")
        return value

    def _parse_block(self, index: int, indent: int) -> tuple[Any, int]:
        if index >= len(self.lines):
            return {}, index
        current_indent, content = self.lines[index]
        if current_indent < indent:
            return {}, index
        if content.startswith("- "):
            return self._parse_list(index, current_indent)
        return self._parse_mapping(index, current_indent)

    def _parse_mapping(self, index: int, indent: int) -> tuple[dict[str, Any], int]:
        result: dict[str, Any] = {}
        while index < len(self.lines):
            current_indent, content = self.lines[index]
            if current_indent < indent:
                break
            if current_indent > indent:
                raise ContractError(f"unexpected indentation near line {index + 1}")
            if content.startswith("- "):
                break
            key, raw_value = self._split_key_value(content, index)
            if raw_value == "":
                next_index = index + 1
                if next_index >= len(self.lines) or self.lines[next_index][0] <= current_indent:
                    result[key] = {}
                    index = next_index
                else:
                    result[key], index = self._parse_block(next_index, self.lines[next_index][0])
            else:
                result[key] = self._parse_scalar(raw_value)
                index += 1
        return result, index

    def _parse_list(self, index: int, indent: int) -> tuple[list[Any], int]:
        result: list[Any] = []
        while index < len(self.lines):
            current_indent, content = self.lines[index]
            if current_indent < indent:
                break
            if current_indent > indent:
                raise ContractError(f"unexpected list indentation near line {index + 1}")
            if not content.startswith("- "):
                break
            item = content[2:].strip()
            if not item:
                value, index = self._parse_block(index + 1, indent + 2)
                result.append(value)
            elif ":" in item and not item.startswith(("'", '"')):
                key, raw_value = self._split_key_value(item, index)
                entry: dict[str, Any] = {key: self._parse_scalar(raw_value) if raw_value else {}}
                index += 1
                if index < len(self.lines) and self.lines[index][0] > indent:
                    nested, index = self._parse_mapping(index, self.lines[index][0])
                    entry.update(nested)
                result.append(entry)
            else:
                result.append(self._parse_scalar(item))
                index += 1
        return result, index

    @staticmethod
    def _split_key_value(content: str, index: int) -> tuple[str, str]:
        if ":" not in content:
            raise ContractError(f"expected key/value pair near line {index + 1}")
        key, value = content.split(":", 1)
        key = key.strip()
        if not key:
            raise ContractError(f"empty key near line {index + 1}")
        return key, value.strip()

    @staticmethod
    def _parse_scalar(value: str) -> Any:
        if value in {"[]", "{}"}:
            return [] if value == "[]" else {}
        if value in {"true", "false"}:
            return value == "true"
        if value == "null":
            return None
        if re.fullmatch(r"-?\d+", value):
            return int(value)
        if value.startswith(("'", '"')):
            try:
                return json.loads(value)
            except json.JSONDecodeError:
                return value.strip("\"'")
        return value


def validate_context(context_path: Path, schema_path: Path) -> dict[str, Any]:
    if not schema_path.is_file():
        raise ContractError(f"context schema is required with context.yaml: {schema_path}")
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        context = parse_yaml_file(context_path)
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(str(exc)) from exc
    errors: list[str] = []
    _check_schema(schema)
    _validate_schema(context, schema, "$", errors)
    _validate_satellite_semantics(context, errors)
    if errors:
        raise ContractError("context validation failed:\n" + "\n".join(f"- {error}" for error in errors))
    return context


def _json_equal(left: Any, right: Any) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(_json_equal(left[key], right[key]) for key in left)
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(_json_equal(a, b) for a, b in zip(left, right))
    return left == right


def _check_schema(schema: Any, path: str = "$") -> None:
    if not isinstance(schema, dict):
        raise ContractError(f"{path}: unsupported schema; expected an object")
    supported = {
        "$schema", "title", "description", "type", "enum", "minLength", "minimum",
        "maximum", "minItems", "items", "required", "properties", "additionalProperties",
    }
    for key, value in schema.items():
        location = f"{path}.{key}"
        if key not in supported:
            raise ContractError(f"{location}: unsupported schema keyword")
        valid = True
        if key == "$schema":
            valid = value in (
                "http://json-schema.org/draft-07/schema#",
                "https://json-schema.org/draft-07/schema#",
            )
        elif key in {"title", "description"}:
            valid = isinstance(value, str)
        elif key == "type":
            valid = isinstance(value, str) and value in {
                "object", "array", "string", "integer", "number", "boolean", "null",
            }
        elif key == "enum":
            valid = isinstance(value, list) and bool(value) and not any(
                _json_equal(item, earlier) for index, item in enumerate(value) for earlier in value[:index]
            )
        elif key in {"minLength", "minItems"}:
            valid = type(value) is int and value >= 0
        elif key in {"minimum", "maximum"}:
            valid = _matches_type(value, "number")
        elif key == "additionalProperties":
            valid = isinstance(value, bool)
        elif key == "required":
            valid = isinstance(value, list) and all(isinstance(item, str) for item in value)
            if valid:
                valid = len(set(value)) == len(value)
        elif key == "items":
            _check_schema(value, location)
        elif key == "properties":
            valid = isinstance(value, dict)
            if valid:
                for name, child in value.items():
                    _check_schema(child, f"{location}.{name}")
        if not valid:
            raise ContractError(f"{location}: unsupported or malformed schema constraint")


def _validate_schema(value: Any, schema: Mapping[str, Any], path: str, errors: list[str]) -> None:
    expected_type = schema.get("type")
    if expected_type and not _matches_type(value, expected_type):
        errors.append(f"{path}: expected {expected_type}, got {type(value).__name__}")
        return
    if "enum" in schema and not any(_json_equal(value, option) for option in schema["enum"]):
        errors.append(f"{path}: expected one of {schema['enum']}, got {value!r}")
    if isinstance(value, str) and len(value) < schema.get("minLength", 0):
        errors.append(f"{path}: must contain at least {schema['minLength']} character(s)")
    if _matches_type(value, "number"):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: must be >= {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: must be <= {schema['maximum']}")
    if isinstance(value, list):
        if (minimum := schema.get("minItems")) is not None and len(value) < minimum:
            errors.append(f"{path}: must contain at least {minimum} item(s)")
        item_schema = schema.get("items")
        if isinstance(item_schema, Mapping):
            for index, item in enumerate(value):
                _validate_schema(item, item_schema, f"{path}[{index}]", errors)
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}.{key}: required field missing")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    errors.append(f"{path}.{key}: unknown field")
        for key, child_schema in properties.items():
            if key in value and isinstance(child_schema, Mapping):
                _validate_schema(value[key], child_schema, f"{path}.{key}", errors)


def _matches_type(value: Any, expected_type: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": type(value) is int or (isinstance(value, float) and value.is_integer()),
        "number": type(value) is int or (isinstance(value, float) and math.isfinite(value)),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }.get(expected_type, False)


def _validate_satellite_semantics(context: Mapping[str, Any], errors: list[str]) -> None:
    # These checks are the validated satellite contract, not inferred defaults.
    state = context.get("context_state")
    if state not in VALIDATED_STATES:
        errors.append("$.context_state: must be validated, signed, or injected for the Phase 0A gate")
    tools = context.get("mcp_tools", [])
    if isinstance(tools, list) and not any(
        isinstance(tool, Mapping) and tool.get("name") != BUILT_IN_MCP_TOOL for tool in tools
    ):
        errors.append("$.mcp_tools: include at least one MCP tool beyond get_satellite_status")
    tenants = context.get("tenants", {})
    if isinstance(tenants, Mapping) and tenants.get("primary") == tenants.get("secondary_sandbox"):
        errors.append("$.tenants.secondary_sandbox: must differ from primary tenant")
    posture = context.get("write_posture", {})
    if isinstance(posture, Mapping) and posture.get("phase") == "phase_1_pull_only" and posture.get("approved_entities"):
        errors.append("$.write_posture.approved_entities: Phase 1 pull-only cannot approve writes")
    decision = context.get("operator_decision", {})
    if isinstance(decision, Mapping) and decision.get("decision") != "proceed":
        errors.append("$.operator_decision.decision: must be proceed before Phase 0 begins")


def _redact_userinfo(url: str | None) -> str:
    if not url:
        return ""
    # Cover URI authority and scp-like Git remote forms before a renderer sees them.
    url = re.sub(r"(?<=://)[^/@\s]+@", "<redacted>@", url)
    return re.sub(r"^[^/@\s]+@", "<redacted>@", url)


def _git(repo: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ("git", "-C", str(repo), *args),
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except OSError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def measure_repository(repo: Path) -> dict[str, Any]:
    if _git(repo, "rev-parse", "--is-inside-work-tree") != "true":
        raise ContractError(f"not a Git repository: {repo}")
    default_ref = _git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    return {
        "name": repo.name,
        "branch": _git(repo, "rev-parse", "--abbrev-ref", "HEAD"),
        "default_branch": default_ref.split("/", 1)[1] if "/" in default_ref else default_ref,
        "remote": _redact_userinfo(_git(repo, "remote", "get-url", "origin")),
        "graph": _measure_graph(repo),
        "entrypoints": _measure_entrypoints(repo),
        "docs": [name for name in ("README.md", "CLAUDE.md", "GEMINI.md", ".okf", "okf.yaml") if (repo / name).exists()],
    }


def _measure_graph(repo: Path) -> str:
    graph = repo / "graphify-out" / "graph.json"
    if not graph.exists():
        return "unbuilt"
    try:
        json.loads(graph.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return "unreadable"
    return "present"


def _measure_entrypoints(repo: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    package = repo / "package.json"
    if package.exists():
        try:
            scripts = json.loads(package.read_text(encoding="utf-8")).get("scripts") or {}
            preferred = [key for key in ("dev", "start", "serve", "build", "test", "lint") if key in scripts]
            for key in preferred + [key for key in sorted(scripts) if key not in preferred]:
                entries.append((f"npm run {key}", str(scripts[key])[:70]))
        except (OSError, json.JSONDecodeError, AttributeError):
            pass
    makefile = repo / "Makefile"
    if makefile.exists():
        try:
            for line in makefile.read_text(encoding="utf-8").splitlines():
                if re.match(r"^[A-Za-z][^:=]*[:+?]?=", line):
                    continue
                if line[:1].isalpha() and ":" in line and not line.startswith("\t"):
                    target = line.split(":", 1)[0].strip()
                    if target and " " not in target and not target.startswith("."):
                        entries.append((f"make {target}", ""))
        except OSError:
            pass
    pyproject = repo / "pyproject.toml"
    if pyproject.exists():
        try:
            after_section = pyproject.read_text(encoding="utf-8").split("[project.scripts]", 1)
            if len(after_section) == 2:
                for line in after_section[1].splitlines()[1:]:
                    if line.startswith("["):
                        break
                    if "=" in line:
                        entries.append((line.split("=", 1)[0].strip(), ""))
        except OSError:
            pass
    bin_dir = repo / "bin"
    if bin_dir.is_dir():
        executables = sorted(item for item in bin_dir.iterdir() if item.is_file() and os.access(item, os.X_OK))
        for item in executables[:8]:
            entries.append((f"bin/{item.name}", ""))
    unique: list[tuple[str, str]] = []
    seen: set[str] = set()
    for command, description in entries:
        if command not in seen:
            seen.add(command)
            unique.append((command, description))
    return unique[:12]


def render(context: Mapping[str, Any] | None, measured: Mapping[str, Any]) -> bytes:
    lines = [
        "## Agent context (generated - do not hand-edit)",
        "",
        "### Repository shape",
        f"- Repository: `{measured['name']}`",
        f"- Current branch: `{measured['branch'] or 'not measurable'}`",
        f"- Default branch: `{measured['default_branch'] or 'not measurable'}`",
        f"- Origin: `{measured['remote']}`" if measured["remote"] else "- Origin: not configured",
        f"- Graph: {measured['graph']}",
        "- Entrypoints: " + _render_entrypoints(measured["entrypoints"]),
        "- Also present: " + (", ".join(f"`{item}`" for item in measured["docs"]) or "no conventional docs"),
        "",
        "### Domain contract",
    ]
    if context is None:
        lines.append("No validated context.yaml is configured for this repository.")
    else:
        lines.extend(_render_domain(context))
    body = "\n".join(lines).replace("<!--", "&lt;!--").encode("utf-8")
    return BEGIN + b"\n" + body + b"\n\n" + END + b"\n"


def _render_entrypoints(entries: Sequence[tuple[str, str]]) -> str:
    if not entries:
        return "none declared"
    return "; ".join(f"`{command}`" + (f" - {description}" if description else "") for command, description in entries)


def _render_list(values: Sequence[Any]) -> str:
    return "none" if not values else ", ".join(str(value) for value in values)


def _render_domain(context: Mapping[str, Any]) -> list[str]:
    entities = "; ".join(
        f"{item['name']} (source of truth: {item['source_of_truth']}; sensitivity: {item['sensitivity']})"
        for item in context["entities"]
    )
    events = "; ".join(f"{item['name']}: {item['description']}" for item in context["events"])
    tools = "; ".join(f"{item['name']} ({item['access']}): {item['description']}" for item in context["mcp_tools"])
    decision = context["operator_decision"]
    return [
        f"- Context state: {context['context_state']}",
        f"- External system: {context['external_system']['name']} ({context['external_system']['category']})",
        f"- Integration surface: {context['external_system']['integration_surface']}",
        f"- Operator persona: {context['operator_persona']['role']}",
        f"- Responsibilities: {_render_list(context['operator_persona']['responsibilities'])}",
        f"- Domain summary: {context['domain_summary']}",
        f"- Entities: {entities}",
        f"- Events: {events}",
        f"- MCP tools: {tools}",
        f"- Tier: {context['tier']['level']} - {context['tier']['rationale']}",
        f"- Standalone faces: execution={context['standalone_face']['execution_face']}; decision={context['standalone_face']['decision_face']}",
        f"- Write posture: {context['write_posture']['phase']}; approved entities={_render_list(context['write_posture']['approved_entities'])}",
        f"- Operator-owned fields: {_render_list(context['operator_owned_fields'])}",
        f"- Canonical fields: {_render_list(context['canonical_fields'])}",
        f"- Tenants: primary={context['tenants']['primary']}; secondary or sandbox={context['tenants']['secondary_sandbox']}",
        f"- Access model: users={_render_list(context['access_model']['users'])}; roles={_render_list(context['access_model']['roles'])}; entitlements={_render_list(context['access_model']['entitlements'])}",
        f"- Operator decision: {decision['decision']} by {decision['signer_role']} on {decision['signed_at']}; {decision['notes']}",
    ]


def _single_pair(content: bytes, begin: bytes, end: bytes, label: str) -> tuple[int, int] | None:
    begins = content.count(begin)
    ends = content.count(end)
    if begins == ends == 0:
        return None
    if begins != 1 or ends != 1:
        raise ContractError(f"malformed or duplicate {label} marker pair")
    start = content.index(begin)
    stop = content.index(end, start + len(begin))
    return start, stop + len(end)


def _legacy_ground_pair(content: bytes) -> tuple[int, int] | None:
    begins = list(GROUND_BEGIN.finditer(content))
    ends = content.count(GROUND_END)
    if not begins and not ends:
        return None
    if len(begins) != 1 or ends != 1:
        raise ContractError("malformed or duplicate GROUND-TRUTH marker pair")
    stop = content.index(GROUND_END, begins[0].end())
    return begins[0].start(), stop + len(GROUND_END)


def inspect_markers(content: bytes) -> tuple[tuple[int, int] | None, list[tuple[int, int]]]:
    current = _single_pair(content, BEGIN, END, "AGENT-CONTEXT")
    # The generated envelope owns its terminal LF. Include it in the comparison
    # and replacement range so a byte-identical rerun cannot accumulate blank lines.
    if current is not None and content[current[1]:current[1] + 1] == b"\n":
        current = (current[0], current[1] + 1)
    domain = _single_pair(content, DOMAIN_BEGIN, DOMAIN_END, "DOMAIN SPECIALIZATION")
    if domain is not None:
        start, stop = domain
        if content[max(0, start - len(DOMAIN_HEADING)):start] == DOMAIN_HEADING:
            domain = (start - len(DOMAIN_HEADING), stop)
    ground = _legacy_ground_pair(content)
    legacy = [pair for pair in (domain, ground) if pair is not None]
    for left, right in zip(sorted(legacy), sorted(legacy)[1:]):
        if left[1] > right[0]:
            raise ContractError("overlapping legacy marker pairs")
    if current is not None and legacy:
        raise ContractError("AGENT-CONTEXT cannot coexist with legacy marker pairs")
    return current, sorted(legacy)


def replace_legacy(content: bytes, pairs: Sequence[tuple[int, int]], block: bytes) -> bytes:
    pieces: list[bytes] = []
    cursor = 0
    for index, (start, stop) in enumerate(pairs):
        pieces.append(content[cursor:start])
        if index == 0:
            pieces.append(block)
        cursor = stop
    pieces.append(content[cursor:])
    return b"".join(pieces)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("mode", nargs="?")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--context")
    parser.add_argument("--schema")
    parser.add_argument("--migrate-legacy", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args(argv)
    if args.help:
        print(usage(), end="")
        return 0
    if args.mode not in {"emit", "check"}:
        print(usage(), file=sys.stderr, end="")
        return 2
    if args.migrate_legacy and args.mode != "emit":
        print("error: --migrate-legacy is valid only with emit", file=sys.stderr)
        return 2
    try:
        repo = Path(args.repo).resolve()
        if not repo.is_dir():
            raise ContractError(f"not a directory: {repo}")
        context_path = Path(args.context).resolve() if args.context else repo / "context.yaml"
        schema_path = Path(args.schema).resolve() if args.schema else repo / "context.schema.json"
        context = validate_context(context_path, schema_path) if context_path.is_file() else None
        measured = measure_repository(repo)
        wanted = render(context, measured)
        agents = repo / "AGENTS.md"
        content = agents.read_bytes() if agents.exists() else b""
        current, legacy = inspect_markers(content)
        if args.mode == "check":
            if legacy:
                raise ContractError("legacy marker pair present; migrate deliberately with emit --migrate-legacy")
            if current is None:
                raise ContractError("missing AGENT-CONTEXT marker pair")
            if content[current[0]:current[1]] != wanted:
                raise ContractError("drift: AGENT-CONTEXT differs; run fm-agent-context.py emit")
            print(f"ok: {repo.name}")
            return 0
        if legacy:
            if not args.migrate_legacy:
                raise ContractError("legacy marker pair present; rerun with emit --migrate-legacy")
            updated = replace_legacy(content, legacy, wanted)
        elif args.migrate_legacy:
            raise ContractError("no legacy marker pair remains to migrate")
        elif current is not None:
            updated = content[:current[0]] + wanted + content[current[1]:]
        else:
            updated = content + (b"" if not content or content.endswith(b"\n") else b"\n") + wanted
        candidate, remaining_legacy = inspect_markers(updated)
        if candidate is None or remaining_legacy or updated[candidate[0]:candidate[1]] != wanted:
            raise ContractError("invalid generated AGENT-CONTEXT candidate")
        if updated != content:
            agents.write_bytes(updated)
            print(f"wrote: {repo.name}")
        else:
            print(f"unchanged: {repo.name}")
        return 0
    except (ContractError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
