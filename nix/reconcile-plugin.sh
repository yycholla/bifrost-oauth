state_dir="$1"
plugin_source="$2"
plugin_path="$state_dir/plugins/codex-oauth.so"
database="$state_dir/config.db"

install -d -m 0700 "$state_dir/plugins"
ln -sfn "$plugin_source" "$plugin_path"

if [[ -f "$database" ]] &&
  [[ "$(sqlite3 "$database" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'config_plugins';")" = 1 ]]; then
  sqlite3 "$database" \
    "UPDATE config_plugins SET path = '$plugin_path' WHERE name = 'codex-subscription-oauth' AND path <> '$plugin_path';"
fi
