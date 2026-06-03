#!/bin/sh
# claudegotchi uninstaller — removes tagged hooks from ~/.claude/settings.json
# and the support dir. Foreign hook entries are left intact (tag-matched prune).
#
# Homebrew cask note: a cask should additionally `zap trash:` the support dir:
#   zap trash: [
#     "~/Library/Application Support/claudegotchi",
#   ]
# and run this script (or replicate the settings.json prune) in `uninstall script:`.
set -eu

SETTINGS="${HOME}/.claude/settings.json"
SUPPORT="${HOME}/Library/Application Support/claudegotchi"

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys, os, tempfile
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(0)  # leave a corrupt/missing file intact

hooks = data.get("hooks")
if isinstance(hooks, dict):
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            leaves = group.get("hooks") if isinstance(group, dict) else None
            if isinstance(leaves, list):
                leaves[:] = [h for h in leaves
                             if not (isinstance(h, dict) and h.get("_claudegotchi") is True)]
                if not leaves:
                    continue  # drop now-empty group
            kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]

d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("pruned claudegotchi hooks from", path)
PY
else
  echo "no settings.json at $SETTINGS (nothing to prune)"
fi

if [ -d "$SUPPORT" ]; then
  rm -rf "$SUPPORT"
  echo "removed $SUPPORT"
fi

echo "claudegotchi hooks uninstalled."
