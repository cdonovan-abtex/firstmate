#!/usr/bin/env bash
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-signals-isolation)

for layout in directory root-link cli-link settings-link; do
  case_dir="$TMP_ROOT/$layout"
  operator_home="$case_dir/operator"
  store="$case_dir/store"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$operator_home" "$store/antigravity-cli" "$case_dir/tmp"
  printf '%s\n' '{"trustedWorkspaces":["original"],"theme":"kept"}' > "$store/antigravity-cli/settings.json"
  case "$layout" in
    directory) cp -R "$store" "$operator_home/.gemini" ;;
    root-link) ln -s "$store" "$operator_home/.gemini" ;;
    cli-link)
      mkdir "$operator_home/.gemini"
      ln -s "$store/antigravity-cli" "$operator_home/.gemini/antigravity-cli"
      ;;
    settings-link)
      mkdir -p "$operator_home/.gemini/antigravity-cli"
      ln -s "$store/antigravity-cli/settings.json" "$operator_home/.gemini/antigravity-cli/settings.json"
      ;;
  esac
  cp "$operator_home/.gemini/antigravity-cli/settings.json" "$case_dir/original.json"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
exit 99
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
shift 2
case "$1" in
  new-session)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -c ]; then workspace=$2; break; fi
      shift
    done
    staged="${workspace%/workspace}/home/.gemini/antigravity-cli/settings.json"
    cp "$staged" "$CASE_DIR/staged-before.json"
    printf '%s\n' '{"trustedWorkspaces":["isolated-lab"],"theme":"kept"}' > "$staged"
    cp "$staged" "$CASE_DIR/staged-after.json"
    exit 1
    ;;
  kill-server) exit 0 ;;
esac
exit 99
SH
  chmod +x "$fakebin/agy" "$fakebin/tmux"
  if out=$(PATH="$fakebin:$PATH" HOME="$operator_home" TMPDIR="$case_dir/tmp" \
    CASE_DIR="$case_dir" FM_AGY_SIGNALS_LIVE=1 \
    bash "$ROOT/tests/fm-agy-signals-live-e2e.test.sh" 2>&1); then
    fail "$layout: fixture unexpectedly reached a live launch"
  fi
  assert_contains "$out" 'could not start the isolated tmux server' "$layout: staging did not reach the controlled backend boundary"
  cmp "$case_dir/original.json" "$case_dir/staged-before.json" || fail "$layout: staged settings lost existing configuration"
  jq -e '.trustedWorkspaces == ["isolated-lab"] and .theme == "kept"' "$case_dir/staged-after.json" >/dev/null \
    || fail "$layout: staged settings did not accept isolated writes"
  cmp "$case_dir/original.json" "$operator_home/.gemini/antigravity-cli/settings.json" \
    || fail "$layout: staged trust write changed operator settings"
  cmp "$case_dir/original.json" "$store/antigravity-cli/settings.json" \
    || fail "$layout: staged trust write changed linked settings"
  pass "$layout: live AGY guard stages writable settings without changing the source store"
done
