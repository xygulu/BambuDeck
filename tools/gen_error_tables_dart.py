#!/usr/bin/env python3
"""Generate Dart error-text tables from the Bambu error feed JSON.

Reads tools/data/hms_en.json (downloaded from e.bambulab.com query.php,
same source BambuHelper's tools/gen_error_tables.py uses) and emits
packages/bambu_protocol/lib/src/error_text_tables.dart as const Dart maps
keyed by lowercase hex: HMS keys are the 16-char attr+code ecode body,
print_error keys the 8-char code. Regenerate after refreshing the JSON:

    python3 tools/gen_error_tables_dart.py
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "tools" / "data" / "hms_en.json"
OUT = ROOT / "packages" / "bambu_protocol" / "lib" / "src" / "error_text_tables.dart"

HEADER = """\
// Error-text tables - GENERATED, DO NOT EDIT.
// Regenerate with: python3 tools/gen_error_tables_dart.py
//
// Source: tools/data/hms_en.json (https://e.bambulab.com/query.php?lang=en),
// the same feed BambuHelper's include/error_tables is built from.
// Feed ver: {ver}
//
// Keys are lowercase hex. HMS: 16 chars = attr(8) + code(8), matching
// [HmsEntry.hexKey]. print_error: 8 chars = the raw code hex.
// ignore_for_file: lines_longer_than_80_chars
"""


def dart_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def main() -> None:
    doc = json.loads(SRC.read_text(encoding="utf-8"))
    ver = str(doc.get("ver", "unknown"))
    hms: dict[str, str] = doc.get("hms", {})
    err: dict[str, str] = doc.get("err", {})
    wiki: dict[str, str] = doc.get("wiki", {})

    lines = [HEADER.format(ver=ver)]
    lines.append(f"const String kErrorTableVersion = '{ver}';\n")

    lines.append(f"const Map<String, String> kHmsErrorText = {{")
    for key in sorted(hms):
        lines.append(f"  '{key}': {dart_str(hms[key])},")
    lines.append("};\n")

    lines.append(f"const Map<String, String> kPrintErrorText = {{")
    for key in sorted(err):
        lines.append(f"  '{key}': {dart_str(err[key])},")
    lines.append("};\n")

    # Not every code has a wiki page; the map stays small enough to ship.
    lines.append(f"const Map<String, String> kHmsWikiPath = {{")
    for key in sorted(wiki):
        lines.append(f"  '{key}': {dart_str(wiki[key])},")
    lines.append("};\n")

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} "
          f"(hms {len(hms)}, err {len(err)}, wiki {len(wiki)}, ver {ver})")


if __name__ == "__main__":
    main()
