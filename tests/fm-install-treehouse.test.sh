#!/usr/bin/env bash
# Deterministic coverage for the exact CI Treehouse release pin.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-treehouse.sh"

test_ci_treehouse_pin_and_checksum() {
  local tmp fakebin dest url_log out
  tmp=$(fm_test_tmproot fm-treehouse-installer)
  fakebin=$(fm_fakebin "$tmp")
  dest="$tmp/bin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo Linux;; -m) echo x86_64;; esac
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2;; *) url=$1; shift;; esac
done
printf '%s\n' "$url" > "${CURL_URL_LOG:?}"
: > "$out"
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' 2fe3e01220ae51a967c3e5ba6ccf10ec83bdbae8e420368d194285a8d04c9ef8 "$1"
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then
    printf '#!/usr/bin/env bash\necho v2.1.1\n' > "$2/treehouse"
    chmod +x "$2/treehouse"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin"/*
  url_log="$tmp/url"
  out=$(CURL_URL_LOG="$url_log" PATH="$fakebin:$PATH" "$INSTALLER" "$dest" 2>&1) \
    || fail "pinned Treehouse installer failed: $out"
  assert_contains "$(cat "$url_log")" \
    "https://github.com/kunchenguid/treehouse/releases/download/v2.1.1/treehouse-v2.1.1-linux-amd64.tar.gz" \
    "CI installer did not consume the exact v2.1.1 Linux asset"
  assert_contains "$out" "v2.1.1" "installer did not verify the exact installed version"
  pass "Treehouse CI installer pins v2.1.1 and its published Linux checksum"
}

test_ci_treehouse_pin_and_checksum
