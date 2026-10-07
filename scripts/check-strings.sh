#!/usr/bin/env bash
# Checks Resources/Localization against the strings the code actually localizes.
#
# The compiler extracts every key passed to a localizing API (Text/Button/Label literals,
# String(localized:), LocalizedStringKey/Resource, with interpolations as %@ / %lld / %lf)
# via -emit-localized-strings, the same mechanism Xcode uses. Plain `String` values shown
# verbatim are NOT seen here; wrap them in String(localized:) in code.
#
# Usage: scripts/check-strings.sh [--keys]   (--keys prints the extracted keys and exits)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L10N="$ROOT/Resources/Localization"
SCRATCH="$ROOT/.build/l10n-check"
OUT="$SCRATCH/stringsdata"

# Fresh build every run (~1 min): an up-to-date build would emit no .stringsdata, and deleting
# single module folders confuses SwiftPM's build database.
rm -rf "$SCRATCH"
mkdir -p "$OUT"
# Separate scratch path: the extra flags must not invalidate the regular build cache.
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --target MemeCam \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >"$SCRATCH/build.log" 2>&1 \
  || { tail -30 "$SCRATCH/build.log"; exit 1; }

for f in "$L10N"/*.lproj/*.strings "$L10N"/*.lproj/*.stringsdict; do
  if [[ -e "$f" ]]; then plutil -lint -s "$f"; fi
done

/usr/bin/python3 - "$OUT" "$L10N" "${1:-}" <<'PY'
import glob, json, os, plistlib, re, subprocess, sys
out, l10n, mode = sys.argv[1], sys.argv[2], sys.argv[3]

keys = {}
for path in glob.glob(os.path.join(out, "**", "*.stringsdata"), recursive=True):
    data = json.load(open(path, encoding="utf-8"))
    for table, entries in data.get("tables", {}).items():
        for e in entries:
            keys.setdefault(e["key"], f'{data["source"]}:{e["location"]["startingLine"]}')
# Keys with no letters (symbols, shortcuts, numbers) need no translation.
keys = {k: v for k, v in keys.items() if re.search(r"[A-Za-z]", re.sub(r"%(?:\d+\$)?(?:lld|ld|d|lf|f|@)", "", k))}

if mode == "--keys":
    for k in sorted(keys): print(f"{k}\t{keys[k]}")
    sys.exit(0)

def table(lang):
    d = {}
    p = os.path.join(l10n, f"{lang}.lproj", "Localizable.strings")
    if os.path.exists(p):
        d.update(parse_strings(p))
    p = os.path.join(l10n, f"{lang}.lproj", "Localizable.stringsdict")
    if os.path.exists(p):
        d.update({k: "<plural>" for k in plistlib.load(open(p, "rb"))})
    return d

def parse_strings(path):
    # `plutil -convert json` understands the old-style .strings format.
    raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], check=True, capture_output=True).stdout
    return json.loads(raw)

def specifiers(s):
    return sorted(re.findall(r"%(?:\d+\$)?(?:lld|ld|d|lf|f|@)", s))

failed = False
tables = {lang: table(lang) for lang in ("en", "ru")}
for lang, t in tables.items():
    missing = sorted(set(keys) - set(t))
    unused = sorted(set(t) - set(keys))
    for k in missing:
        failed = True
        print(f"{lang}: missing  {k!r}  ({keys[k]})")
    for k in unused:
        print(f"{lang}: unused   {k!r}")
    for k, v in t.items():
        if v != "<plural>" and specifiers(re.sub(r"%(\d+)\$", "%", k)) != specifiers(re.sub(r"%(\d+)\$", "%", v)):
            failed = True
            print(f"{lang}: format mismatch  {k!r} -> {v!r}")
print(f"{len(keys)} keys in code; en {len(tables['en'])}, ru {len(tables['ru'])} entries")
sys.exit(1 if failed else 0)
PY
