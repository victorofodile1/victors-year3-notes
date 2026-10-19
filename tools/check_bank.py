#!/usr/bin/env python3
"""Check question bank files against tools/BANK_FORMAT.md.

Usage: python3 tools/check_bank.py bank/a.json [bank/b.json ...]
       python3 tools/check_bank.py --all
       python3 tools/check_bank.py --write-index   (check all, list passing ones in bank/index.json)
"""
import collections
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_lesson import (DOMAINS, ROOT, check_labs, check_method, check_visual, is_str,  # noqa: E402
                          load_notes, words)


def check(path, notes):
    errs = []
    try:
        B = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return [f"not valid JSON: {e}"], 0
    cid = B.get("id")
    if cid not in notes:
        return [f"unknown id {cid!r}"], 0
    if os.path.basename(path) != cid + ".json":
        errs.append("file name must be <id>.json")
    N = notes[cid]
    qs = B.get("questions") or []
    n_sub = sum(len(N[d]) for d in DOMAINS)
    want_lo, want_hi = max(24, min(45, 2 * n_sub)), 45
    if not want_lo <= len(qs) <= want_hi:
        errs.append(f"{len(qs)} questions (want {want_lo} to {want_hi})")

    # lesson questions must not be repeated
    lesson_stems = set()
    lp = os.path.join(ROOT, "lessons", cid + ".json")
    if os.path.exists(lp):
        L = json.load(open(lp, encoding="utf-8"))
        lesson_stems = {(q.get("stem") or "")[:70] for q in (L.get("practice") or []) + (L.get("technique") or [])}

    covered_sub = set()
    covered_pt = set()
    seen_stems = set()
    for i, q in enumerate(qs):
        w = f"q[{i}]"
        if q.get("d") not in DOMAINS:
            errs.append(f"{w}: bad domain {q.get('d')!r}")
        o = q.get("o") or []
        if not is_str(q.get("stem")) or not is_str(q.get("q")) or len(o) != 5 \
                or not isinstance(q.get("a"), int) or not 0 <= q["a"] < 5 or not is_str(q.get("e")):
            errs.append(f"{w}: needs stem, q, 5 options, valid a, e")
            continue
        if words(q["stem"]) > 110:
            errs.append(f"{w}: stem too long ({words(q['stem'])} words)")
        if [x.lower() for x in o] != sorted(x.lower() for x in o):
            errs.append(f"{w}: options must be alphabetical")
        check_method(q.get("steps"), q["a"], q.get("stem"), w, errs, need=3)
        check_labs(q, w, errs)
        check_visual(q.get("visual"), w, errs)
        key = q["stem"][:70]
        if key in lesson_stems:
            errs.append(f"{w}: repeats a lesson question")
        if key in seen_stems:
            errs.append(f"{w}: duplicate stem")
        seen_stems.add(key)
        cov = q.get("covers") or []
        if not cov:
            errs.append(f"{w}: needs covers")
        for c in cov:
            if not (isinstance(c, list) and len(c) == 3 and c[0] in DOMAINS and isinstance(c[1], int)
                    and 0 <= c[1] < len(N[c[0]]) and isinstance(c[2], list)):
                errs.append(f"{w}: bad covers entry {c!r}")
                continue
            covered_sub.add((c[0], c[1]))
            npts = len(N[c[0]][c[1]]["points"])
            for pi in c[2]:
                if not isinstance(pi, int) or not 0 <= pi < npts:
                    errs.append(f"{w}: covers point {pi!r} not in {c[0]}[{c[1]}]")
                else:
                    covered_pt.add((c[0], c[1], pi))

    missing = [f"{d}[{k}]" for d in DOMAINS for k in range(len(N[d])) if (d, k) not in covered_sub]
    if missing:
        errs.append(f"note subsections not examined: {', '.join(missing)}")
    total_pts = sum(len(s["points"]) for d in DOMAINS for s in N[d])
    pct = 100 * len(covered_pt) / max(1, total_pts)
    if pct < 75:
        errs.append(f"only {pct:.0f}% of note points examined (want at least 75%)")

    cnt = collections.Counter(q.get("d") for q in qs)
    if qs and cnt["diagnosis"] < 0.35 * len(qs):
        errs.append(f"only {cnt['diagnosis']} diagnosis-type questions (want at least 35%)")
    for d, need in (("diagnosis", 3), ("investigation", 3), ("management", 3), ("science", 2)):
        if N[d] and cnt[d] < need:
            errs.append(f"only {cnt[d]} {d} questions (want at least {need})")
    letters = collections.Counter(q.get("a") for q in qs)
    if qs and letters.most_common(1)[0][1] > 0.3 * len(qs) + 1:
        errs.append(f"answers too often the same letter: {dict(letters)}")
    return errs, round(pct)


def main():
    args = sys.argv[1:]
    write_index = "--write-index" in args
    if write_index or args == ["--all"]:
        args = sorted(a for a in glob.glob(os.path.join(ROOT, "bank", "*.json")) if not a.endswith("index.json"))
    notes = load_notes()
    bad, passed = 0, {}
    for a in args:
        errs, pct = check(a, notes)
        name = os.path.basename(a)
        if errs:
            bad += 1
            print(f"FAIL {name}")
            for e in errs:
                print("   -", e)
        else:
            n = len(json.load(open(a, encoding="utf-8"))["questions"])
            passed[name[:-5]] = {"n": n, "cover": pct}
            print(f"OK   {name}  ({n} questions, {pct}% of note points examined)")
    if write_index:
        with open(os.path.join(ROOT, "bank", "index.json"), "w") as f:
            json.dump(passed, f, sort_keys=True)
        print(f"wrote bank/index.json with {len(passed)} banks, {sum(v['n'] for v in passed.values())} questions")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
