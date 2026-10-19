#!/usr/bin/env python3
"""Check notes-visual files against tools/NOTESVIS_FORMAT.md.

Usage: python3 tools/check_notesvis.py notesvis/a.json [...]
       python3 tools/check_notesvis.py --all
       python3 tools/check_notesvis.py --write-index   (check all, list passing ones, rebuild the shared glossary)
"""
import collections
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_lesson import DOMAINS, ROOT, check_visual, is_str, load_notes, words  # noqa: E402


def check(path, notes):
    errs = []
    try:
        V = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return [f"not valid JSON: {e}"]
    cid = V.get("id")
    if cid not in notes:
        return [f"unknown id {cid!r}"]
    if os.path.basename(path) != cid + ".json":
        errs.append("file name must be <id>.json")
    N = notes[cid]
    vs = V.get("visuals") or []
    if not 6 <= len(vs) <= 14:
        errs.append(f"{len(vs)} visuals (want 6 to 14)")
    per = collections.Counter()
    kinds = set()
    for i, v in enumerate(vs):
        w = f"visuals[{i}]"
        d = v.get("d")
        if d not in DOMAINS or not isinstance(v.get("after"), int) or not 0 <= v["after"] < len(N[d] or [None]):
            errs.append(f"{w}: needs d and a valid after index")
            continue
        per[d] += 1
        if not is_str(v.get("title")):
            errs.append(f"{w}: needs a title")
        if v.get("text") and words(v["text"]) > 35:
            errs.append(f"{w}: text too long")
        t = v.get("type")
        if t == "visual":
            check_visual(v.get("visual"), w, errs)
            kinds.add((v.get("visual") or {}).get("kind"))
        elif t == "flow":
            if not 3 <= len(v.get("nodes") or []) <= 8:
                errs.append(f"{w}: flow needs 3 to 7 nodes")
            kinds.add("flow")
        elif t == "compare":
            head, rows = v.get("head") or [], v.get("rows") or []
            if not head or not rows or any(len(r) != len(head) for r in rows):
                errs.append(f"{w}: compare rows must match head length")
            kinds.add("compare")
        else:
            errs.append(f"{w}: bad type {t!r}")
    for d in DOMAINS:
        if N[d] and per[d] < 1:
            errs.append(f"no visual in {d}")
    ns = len(N["science"])
    if ns and per["science"] < min(3, ns):
        errs.append(f"only {per['science']} science visuals (want at least {min(3, ns)})")
    if len(kinds) < 3:
        errs.append(f"only {len(kinds)} kinds of visual (want at least 3)")
    g = V.get("glossary")
    if not isinstance(g, dict) or len(g) < 10:
        errs.append("glossary needs at least 10 terms")
    else:
        for term, de in g.items():
            if not is_str(term) or not is_str(de) or words(de) > 30:
                errs.append(f"glossary[{term!r}]: needs a definition under 30 words")
    return errs


def main():
    args = sys.argv[1:]
    write_index = "--write-index" in args
    if write_index or args == ["--all"]:
        args = sorted(a for a in glob.glob(os.path.join(ROOT, "notesvis", "*.json")) if not a.endswith("index.json"))
    notes = load_notes()
    bad, passed = 0, []
    for a in args:
        errs = check(a, notes)
        if errs:
            bad += 1
            print(f"FAIL {os.path.basename(a)}")
            for e in errs:
                print("   -", e)
        else:
            passed.append(os.path.basename(a)[:-5])
            print(f"OK   {os.path.basename(a)}")
    if write_index:
        with open(os.path.join(ROOT, "notesvis", "index.json"), "w") as f:
            json.dump(sorted(passed), f)
        # shared glossary = lesson glossaries + notes glossaries
        gloss = {}
        for cid in sorted(json.load(open(os.path.join(ROOT, "lessons", "index.json")))):
            for t, d in (json.load(open(os.path.join(ROOT, "lessons", cid + ".json"), encoding="utf-8")).get("glossary") or {}).items():
                gloss.setdefault(t, d)
        for cid in sorted(passed):
            for t, d in (json.load(open(os.path.join(ROOT, "notesvis", cid + ".json"), encoding="utf-8")).get("glossary") or {}).items():
                gloss.setdefault(t, d)
        with open(os.path.join(ROOT, "lessons", "glossary.json"), "w", encoding="utf-8") as f:
            json.dump(gloss, f, ensure_ascii=False, indent=0, sort_keys=True)
        print(f"wrote notesvis/index.json with {len(passed)} conditions; glossary now {len(gloss)} terms")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
