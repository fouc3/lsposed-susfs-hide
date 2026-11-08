#!/usr/bin/env bash
# Package the module into a flashable zip.
set -euo pipefail
cd "$(dirname "$0")"
rm -f SystemHelper.zip
if command -v zip >/dev/null 2>&1; then
  (cd module && zip -9 -r ../SystemHelper.zip .)
else
  (cd module && python3 - <<'PY'
import os, zipfile
with zipfile.ZipFile("../SystemHelper.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, _dirs, files in os.walk("."):
        for fn in sorted(files):
            p = os.path.join(root, fn)
            z.write(p, os.path.relpath(p, ".").replace(os.sep, "/"))
PY
  )
fi
echo "built SystemHelper.zip"