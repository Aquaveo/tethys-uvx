#!/usr/bin/env bash
set -euo pipefail
# Gather and publish portal static
# tethysdash plugin static, before collectstatic
if SCRIPT_DIR="$(python -c 'import tethysapp.tethysdash as m, os; print(os.path.dirname(m.__file__))' 2>/dev/null)"; then
  ( cd "$SCRIPT_DIR" && python collect_plugin_static.py )
else
  echo "tethysdash not installed -- skipping plugin static collection."
fi

# collect everything
tethys manage collectstatic --noinput

echo "static published."
