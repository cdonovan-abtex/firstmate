#!/usr/bin/env bash
# Deterministic coverage for the exact CI Treehouse release pin.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-treehouse.sh"
TREEHOUSE_LINUX_AMD64_SHA=2fe3e01220ae51a967c3e5ba6ccf10ec83bdbae8e420368d194285a8d04c9ef8

make_treehouse_fakebin() {
  local tmp=$1 fakebin
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -s) printf '%s\n' "${FAKE_UNAME_S:?}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:?}" ;;
esac
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" > "${CURL_URL_LOG:?}"
: > "$out"
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 1 ] || exit 2
printf 'sha256sum\n' >> "${CHECKSUM_TOOL_LOG:?}"
printf '%s  %s\n' "${FAKE_TREEHOUSE_SHA:?}" "$1"
SH
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 3 ] && [ "$1" = -a ] && [ "$2" = 256 ] || exit 2
printf 'shasum -a 256\n' >> "${CHECKSUM_TOOL_LOG:?}"
printf '%s  %s\n' "${FAKE_TREEHOUSE_SHA:?}" "$3"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then
    printf '#!/usr/bin/env bash\necho %s\n' "${FAKE_TREEHOUSE_VERSION:?}" > "$2/treehouse"
    chmod +x "$2/treehouse"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

run_fake_treehouse_installer() {
  local fakebin=$1 dest=$2 url_log=$3 tool_log=$4 os=$5 arch=$6 sha=$7 version=$8
  shift 8
  BASH_ENV='' CURL_URL_LOG="$url_log" CHECKSUM_TOOL_LOG="$tool_log" \
    FAKE_UNAME_S="$os" FAKE_UNAME_M="$arch" \
    FAKE_TREEHOUSE_SHA="$sha" FAKE_TREEHOUSE_VERSION="$version" \
    PATH="$fakebin:$PATH" "$@" "$INSTALLER" "$dest" 2>&1
}

test_ci_treehouse_platform_pins() {
  local os arch asset sha tmp fakebin dest url_log tool_log out expected_url
  while read -r os arch asset sha; do
    tmp=$(fm_test_tmproot "fm-treehouse-${os}-${arch}")
    fakebin=$(make_treehouse_fakebin "$tmp")
    dest="$tmp/bin"
    url_log="$tmp/url"
    tool_log="$tmp/checksum-tool"
    out=$(run_fake_treehouse_installer "$fakebin" "$dest" "$url_log" "$tool_log" \
      "$os" "$arch" "$sha" v2.1.1) \
      || fail "pinned Treehouse installer failed for ${os}-${arch}: $out"
    expected_url="https://github.com/kunchenguid/treehouse/releases/download/v2.1.1/$asset"
    [ "$(cat "$url_log")" = "$expected_url" ] \
      || fail "CI installer did not consume the exact v2.1.1 ${os}-${arch} asset"
    [ "$(cat "$tool_log")" = sha256sum ] \
      || fail "CI installer did not verify ${os}-${arch} with sha256sum"
    assert_contains "$out" "installed treehouse v2.1.1" \
      "installer did not verify the exact installed version for ${os}-${arch}"
  done <<'CASES'
Linux x86_64 treehouse-v2.1.1-linux-amd64.tar.gz 2fe3e01220ae51a967c3e5ba6ccf10ec83bdbae8e420368d194285a8d04c9ef8
Linux aarch64 treehouse-v2.1.1-linux-arm64.tar.gz 980367c0233274eb3181a19a2ca8ec69d09b4a588ba27367937d336f9a2c938e
Linux arm64 treehouse-v2.1.1-linux-arm64.tar.gz 980367c0233274eb3181a19a2ca8ec69d09b4a588ba27367937d336f9a2c938e
Darwin arm64 treehouse-v2.1.1-darwin-arm64.tar.gz deabeb7153bad14659e98da78de5334afecaeaac7e05988b106a4888646747d3
Darwin x86_64 treehouse-v2.1.1-darwin-amd64.tar.gz f6f6bd71fe8279826aa35f201e79f34106c1c4056179e3e8141942027dd992a6
CASES
  pass "Treehouse CI installer pins every Linux/macOS asset and checksum to v2.1.1"
}

test_required_ci_job_consumes_treehouse_pin() {
  local tmp fakebin step out
  tmp=$(fm_test_tmproot fm-treehouse-ci-job)
  fakebin=$(make_treehouse_fakebin "$tmp")
  step="$tmp/install-treehouse-step.sh"

  # The workflow is machine-consumed configuration, so normalize it as YAML and
  # execute the selected job step instead of treating source text as evidence.
  ruby - "$ROOT/.github/workflows/ci.yml" "$step" <<'RUBY'
require "yaml"

workflow = YAML.load_file(ARGV.fetch(0))
steps = workflow.fetch("jobs").fetch("tests-herdr").fetch("steps")
matches = steps.select { |candidate| candidate["name"] == "Install pinned Treehouse" }
abort "expected exactly one tests-herdr Treehouse install step" unless matches.length == 1
File.write(ARGV.fetch(1), matches.fetch(0).fetch("run"))
RUBY

  : > "$tmp/github-path"
  out=$(CURL_URL_LOG="$tmp/url" CHECKSUM_TOOL_LOG="$tmp/checksum-tool" \
    FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 \
    FAKE_TREEHOUSE_SHA="$TREEHOUSE_LINUX_AMD64_SHA" FAKE_TREEHOUSE_VERSION=v2.1.1 \
    RUNNER_TEMP="$tmp" GITHUB_PATH="$tmp/github-path" PATH="$fakebin:$PATH" \
    bash "$step" 2>&1) \
    || fail "required CI Treehouse install step failed: $out"

  [ "$(cat "$tmp/url")" = \
    "https://github.com/kunchenguid/treehouse/releases/download/v2.1.1/treehouse-v2.1.1-linux-amd64.tar.gz" ] \
    || fail "required CI job did not consume the exact v2.1.1 installer asset"
  [ "$(cat "$tmp/github-path")" = "$tmp/bin" ] \
    || fail "required CI job did not publish the Treehouse installation directory"
  [ "$("$tmp/bin/treehouse" --version)" = v2.1.1 ] \
    || fail "required CI job did not install the exact Treehouse v2.1.1 pin"
  assert_contains "$out" "installed treehouse v2.1.1" \
    "required CI job did not execute the pinned installer"
  pass "required CI Herdr job consumes the exact Treehouse v2.1.1 installer pin"
}

test_ci_treehouse_rejects_checksum_drift() {
  local tmp fakebin out code
  tmp=$(fm_test_tmproot fm-treehouse-checksum-drift)
  fakebin=$(make_treehouse_fakebin "$tmp")
  out=$(run_fake_treehouse_installer "$fakebin" "$tmp/bin" "$tmp/url" "$tmp/tool" \
    Linux x86_64 0000000000000000000000000000000000000000000000000000000000000000 v2.1.1)
  code=$?
  expect_code 1 "$code" "Treehouse checksum drift"
  assert_contains "$out" "checksum mismatch for treehouse-v2.1.1-linux-amd64.tar.gz" \
    "installer did not reject checksum drift"
  pass "Treehouse CI installer rejects checksum drift"
}

test_ci_treehouse_rejects_version_drift() {
  local tmp fakebin out code
  tmp=$(fm_test_tmproot fm-treehouse-version-drift)
  fakebin=$(make_treehouse_fakebin "$tmp")
  out=$(run_fake_treehouse_installer "$fakebin" "$tmp/bin" "$tmp/url" "$tmp/tool" \
    Linux x86_64 "$TREEHOUSE_LINUX_AMD64_SHA" v2.1.0)
  code=$?
  expect_code 1 "$code" "Treehouse installed-version drift"
  assert_contains "$out" "installed treehouse version is 'v2.1.0', expected exact pin v2.1.1" \
    "installer did not reject installed-version drift"
  pass "Treehouse CI installer rejects installed-version drift"
}

test_ci_treehouse_preserves_shasum_fallback() {
  local tmp fakebin bash_env out
  tmp=$(fm_test_tmproot fm-treehouse-shasum-fallback)
  fakebin=$(make_treehouse_fakebin "$tmp")
  bash_env="$tmp/bash-env"
  cat > "$bash_env" <<'SH'
command() {
  if [ "$#" -eq 2 ] && [ "$1" = -v ] && [ "$2" = sha256sum ]; then
    return 1
  fi
  builtin command "$@"
}
SH
  out=$(run_fake_treehouse_installer "$fakebin" "$tmp/bin" "$tmp/url" "$tmp/tool" \
    Darwin arm64 deabeb7153bad14659e98da78de5334afecaeaac7e05988b106a4888646747d3 \
    v2.1.1 env BASH_ENV="$bash_env" bash) \
    || fail "Treehouse shasum fallback failed: $out"
  [ "$(cat "$tmp/tool")" = "shasum -a 256" ] \
    || fail "installer did not use the SHA-256 shasum fallback"
  assert_contains "$out" "installed treehouse v2.1.1" \
    "shasum fallback did not install the exact pinned version"
  pass "Treehouse CI installer preserves the shasum fallback"
}

test_ci_treehouse_platform_pins
test_required_ci_job_consumes_treehouse_pin
test_ci_treehouse_rejects_checksum_drift
test_ci_treehouse_rejects_version_drift
test_ci_treehouse_preserves_shasum_fallback
