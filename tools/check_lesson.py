#!/usr/bin/env python3
"""Check lesson files against tools/LESSON_FORMAT.md.

Usage: python3 tools/check_lesson.py lessons/a.json [lessons/b.json ...]
       python3 tools/check_lesson.py --all
       python3 tools/check_lesson.py --write-index   (check all, list passing ones in lessons/index.json)
Prints OK or a list of problems per file. Exit code 1 if any file has problems.
"""
import json, re, sys, glob, os, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOMAINS = ["diagnosis", "investigation", "management", "science"]
STEP_TYPES = {"story", "labs", "ask", "notes", "flow", "compare", "pearl", "trap", "visual"}
PRACTICE_MIX = {"diagnosis": 6, "investigation": 2, "management": 3, "science": 1}
RHYTHMS = {"sinus", "sinus_brady", "sinus_tachy", "af", "flutter", "svt", "vt", "vf", "asystole",
           "first_degree", "mobitz1", "mobitz2", "chb"}
LEADS = {"I", "II", "III", "aVR", "aVL", "aVF", "V1", "V2", "V3", "V4", "V5", "V6"}
LEAD_PATTERNS = {"normal", "st_elev", "st_dep", "t_inv", "q_wave", "peaked_t", "flat_t"}
CXR_TYPES = {"consolidation", "effusion", "pneumothorax", "mass", "cavity", "cardiomegaly", "hilar",
             "free_air", "fibrosis", "pulm_oedema"}
REGIONS = {"RUQ", "epigastric", "LUQ", "R_flank", "umbilical", "L_flank", "RIF", "suprapubic", "LIF"}


def check_visual(v, w, errs):
    if v is None:
        return
    if not isinstance(v, dict):
        errs.append(f"{w}: visual must be an object")
        return
    k = v.get("kind")
    if k == "ecg":
        if v.get("layout") not in ("12lead", "strip"):
            errs.append(f"{w}: ecg layout must be 12lead or strip")
        if v.get("rhythm") not in RHYTHMS:
            errs.append(f"{w}: ecg rhythm {v.get('rhythm')!r} unknown")
        for lead, pat in (v.get("leads") or {}).items():
            if lead not in LEADS or pat not in LEAD_PATTERNS:
                errs.append(f"{w}: ecg lead {lead}={pat} unknown")
    elif k == "cxr":
        f = v.get("findings")
        if not isinstance(f, list):
            errs.append(f"{w}: cxr needs findings list")
        for x in f or []:
            if x.get("type") not in CXR_TYPES or x.get("side", "both") not in ("left", "right", "both") \
                    or x.get("zone", "lower") not in ("upper", "middle", "lower"):
                errs.append(f"{w}: bad cxr finding {x}")
    elif k == "scale":
        try:
            lo, hi, val = float(v["min"]), float(v["max"]), float(v["value"])
            assert lo < hi and lo <= val <= hi
            for b in v.get("bands") or []:
                assert len(b) == 4 and b[3] in ("ok", "warn", "bad") and float(b[0]) < float(b[1])
        except Exception:
            errs.append(f"{w}: scale needs min < max, value inside, bands [from,to,label,ok|warn|bad]")
    elif k == "trend":
        x = v.get("x") or []
        ser = v.get("series") or []
        if len(x) < 2 or not 1 <= len(ser) <= 3 or any(len(se.get("values") or []) != len(x) for se in ser) \
                or any(not all(isinstance(n, (int, float)) for n in se.get("values")) for se in ser):
            errs.append(f"{w}: trend needs x labels and 1-3 numeric series of the same length")
    elif k == "abdomen":
        r = v.get("regions") or []
        if not r or any(x not in REGIONS for x in r):
            errs.append(f"{w}: abdomen regions must be from {sorted(REGIONS)}")
    elif k == "coronary":
        if v.get("artery") not in ("RCA", "LAD", "Cx", "LMS"):
            errs.append(f"{w}: coronary artery must be RCA, LAD, Cx or LMS")
    else:
        errs.append(f"{w}: unknown visual kind {k!r}")


def load_notes():
    s = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    m = re.search(r'<script id="data-json" type="application/json">(.*?)</script>', s, re.S)
    return {c["id"]: c for c in json.loads(m.group(1))}


def words(s):
    return len(str(s).split())


def check_method(steps, a, stem, w, errs, need=4):
    if len(steps or []) < need:
        errs.append(f"{w}: needs at least {need} method steps")
        return
    elim_idx = set()
    for s in steps:
        for c in s.get("clues") or []:
            if c not in (stem or ""):
                errs.append(f"{w}: clue not found in stem: {c!r}")
        for e in s.get("elim") or []:
            elim_idx.add(e[0])
        if words(s.get("x") or "") > 60:
            errs.append(f"{w}: method step too long ({words(s.get('x'))} words)")
    want = set(range(5)) - {a}
    if elim_idx != want:
        errs.append(f"{w}: elim must cover wrong options {sorted(want)}, has {sorted(elim_idx)}")
    if not any(s.get("clues") for s in steps):
        errs.append(f"{w}: needs a step with clues")


def is_str(v):
    return isinstance(v, str) and v.strip() != ""


def check(path, notes):
    errs = []
    try:
        L = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return [f"not valid JSON: {e}"]
    cid = L.get("id")
    if cid not in notes:
        return [f"unknown id {cid!r}"]
    if os.path.basename(path) != cid + ".json":
        errs.append("file name must be <id>.json")
    N = notes[cid]

    p = L.get("patient") or {}
    for k in ["name", "sex", "setting", "complaint"]:
        if not is_str(p.get(k)):
            errs.append(f"patient.{k} missing")
    if not isinstance(p.get("age"), int):
        errs.append("patient.age must be a number")

    doms = L.get("domains") or {}
    used_guidelines = False
    n_visual = 0
    for d in DOMAINS:
        D = doms.get(d)
        if not D:
            errs.append(f"domains.{d} missing")
            continue
        if not is_str(D.get("exam")):
            errs.append(f"{d}.exam missing")
        steps = D.get("steps") or []
        if not 4 <= len(steps) <= 20:
            errs.append(f"{d}: {len(steps)} steps (want 6 to 14)")
        seen = collections.Counter()
        for i, st in enumerate(steps):
            w = f"{d}.steps[{i}]"
            t = st.get("type")
            if t not in STEP_TYPES:
                errs.append(f"{w}: bad type {t!r}")
                continue
            if t == "story":
                pts = st.get("points") or []
                if st.get("text") or not 2 <= len(pts) <= 5 or not all(is_str(x) for x in pts):
                    errs.append(f"{w}: story needs 2-5 bullet points (no text paragraph)")
                for x in pts:
                    if words(x) > 18:
                        errs.append(f"{w}: story bullet too long ({words(x)} words): {x[:40]!r}")
            if t == "labs":
                rows = st.get("rows") or []
                if not rows or any(not isinstance(r, list) or len(r) != 4 for r in rows):
                    errs.append(f"{w}: labs rows must be [test,value,range,flag]")
                elif any(r[3] not in ("H", "L", "") for r in rows):
                    errs.append(f"{w}: labs flag must be H, L or empty")
            if t == "ask":
                o = st.get("o") or []
                if not 3 <= len(o) <= 5 or not isinstance(st.get("a"), int) or not 0 <= st["a"] < len(o) or not is_str(st.get("r")) or not is_str(st.get("q")):
                    errs.append(f"{w}: ask needs q, 3-5 options, valid a, r")
            if t == "notes":
                src = st.get("src")
                if src == "guidelines":
                    used_guidelines = True
                elif isinstance(src, int) and 0 <= src < len(N[d]):
                    seen[src] += 1
                else:
                    errs.append(f"{w}: bad src {src!r}")
                if not is_str(st.get("lead")):
                    errs.append(f"{w}: notes needs lead")
                elif words(st["lead"]) > 45:
                    errs.append(f"{w}: lead too long ({words(st['lead'])} words)")
            if t == "flow":
                nodes = st.get("nodes") or []
                if not 3 <= len(nodes) <= 8 or not is_str(st.get("title")):
                    errs.append(f"{w}: flow needs title and 3-7 nodes")
            if t == "compare":
                head = st.get("head") or []
                rows = st.get("rows") or []
                if not head or not rows or any(len(r) != len(head) for r in rows):
                    errs.append(f"{w}: compare rows must match head length")
            if t == "visual":
                n_visual += 1
                if not st.get("visual"):
                    errs.append(f"{w}: visual step needs visual")
                check_visual(st.get("visual"), w, errs)
            if t in ("pearl", "trap") and not is_str(st.get("text")):
                errs.append(f"{w}: {t} needs text")
            for k, v in st.items():
                if isinstance(v, str) and re.search(r"<[a-z/][^>]*>", v):
                    errs.append(f"{w}.{k}: contains HTML")
        missing = [i for i in range(len(N[d])) if seen[i] == 0]
        dup = [i for i, c in seen.items() if c > 1]
        if missing:
            errs.append(f"{d}: notes subsections not covered: {missing}")
        if dup:
            errs.append(f"{d}: notes subsections used twice: {dup}")
    if n_visual < 3:
        errs.append(f"only {n_visual} visual steps (want at least 3)")
    if N.get("guidelines") and not used_guidelines:
        errs.append('guidelines not covered (add a notes step with "src":"guidelines")')

    mcq = L.get("mcq") or []
    if not 8 <= len(mcq) <= 10:
        errs.append(f"mcq: {len(mcq)} questions (want 8 to 10)")
    for i, q in enumerate(mcq):
        if q.get("d") not in DOMAINS or not is_str(q.get("q")) or len(q.get("o") or []) != 4 \
                or not isinstance(q.get("a"), int) or not 0 <= q["a"] < 4 or not is_str(q.get("r")):
            errs.append(f"mcq[{i}]: needs d, q, 4 options, valid a, r")
    if mcq and len({q.get("d") for q in mcq}) < 4:
        errs.append("mcq: must cover all four domains")

    tech = L.get("technique") or []
    if [t.get("d") for t in tech] != DOMAINS:
        errs.append("technique: need exactly 4, one per domain in order")
    for i, t in enumerate(tech):
        w = f"technique[{i}]"
        o = t.get("o") or []
        if len(o) != 5 or not isinstance(t.get("a"), int) or not 0 <= t["a"] < 5:
            errs.append(f"{w}: needs 5 options and valid a")
            continue
        if not is_str(t.get("stem")) or not is_str(t.get("q")):
            errs.append(f"{w}: needs stem and q")
        check_method(t.get("steps"), t["a"], t.get("stem"), w, errs)
        check_labs(t, w, errs)
        check_visual(t.get("visual"), w, errs)

    b = L.get("blurt") or {}
    prompts = b.get("prompts") or []
    if not 8 <= len(prompts) <= 12:
        errs.append(f"blurt: {len(prompts)} prompts (want 8 to 12)")
    pd = [q.get("d") for q in prompts]
    if set(pd) != set(DOMAINS) or pd != sorted(pd, key=DOMAINS.index):
        errs.append("blurt: prompts must cover all four domains, in domain order")
    for i, q in enumerate(prompts):
        w = f"blurt.prompts[{i}]"
        if not is_str(q.get("q")) or not is_str(q.get("tip")):
            errs.append(f"{w}: needs q and tip")
        elif words(q["q"]) > 30:
            errs.append(f"{w}: question too long ({words(q['q'])} words)")
        pts = q.get("points") or []
        if not 2 <= len(pts) <= 6:
            errs.append(f"{w}: {len(pts)} points (want 2 to 6)")
        for j, pt in enumerate(pts):
            k = pt.get("k")
            if not is_str(pt.get("p")) or not is_str(pt.get("why")) or not isinstance(k, list) or not k \
                    or any(not isinstance(g, list) or not g or any(not is_str(a) for a in g) for g in k):
                errs.append(f"{w}.points[{j}]: needs p, why and k (list of keyword lists)")
    gl = L.get("glossary")
    if not isinstance(gl, dict) or not 25 <= len(gl) <= 60:
        errs.append(f"glossary: need 25 to 60 terms (have {len(gl) if isinstance(gl, dict) else 0})")
    else:
        for term, de in gl.items():
            if not is_str(term) or not is_str(de) or words(de) > 30:
                errs.append(f"glossary[{term!r}]: needs a definition under 30 words")

    prac = L.get("practice") or []
    cnt = collections.Counter(q.get("d") for q in prac)
    if len(prac) != 12 or any(cnt[d] != n for d, n in PRACTICE_MIX.items()):
        errs.append(f"practice: need 12 questions as {PRACTICE_MIX} (have {dict(cnt)})")
    elif [q.get("d") for q in prac] != sorted([q.get("d") for q in prac], key=DOMAINS.index):
        errs.append("practice: order must be diagnosis, investigation, management, science")
    if prac:
        obs = sum(1 for q in prac if re.search(r"pulse|blood pressure|BP \d", q.get("stem") or "", re.I))
        labs = sum(1 for q in prac if q.get("labs"))
        if obs < 4:
            errs.append(f"practice: only {obs} stems with observations (want at least 4)")
        if labs < 3:
            errs.append(f"practice: only {labs} questions with labs (want at least 3)")
    for i, q in enumerate(prac):
        w = f"practice[{i}]"
        if not is_str(q.get("stem")) or not is_str(q.get("q")) or len(q.get("o") or []) != 5 \
                or not isinstance(q.get("a"), int) or not 0 <= q["a"] < 5 or not is_str(q.get("e")):
            errs.append(f"{w}: needs stem, q, 5 options, valid a, e")
            continue
        check_method(q.get("steps"), q["a"], q.get("stem"), w, errs)
        check_labs(q, w, errs)
        check_visual(q.get("visual"), w, errs)
    letters = collections.Counter(q.get("a") for q in prac + tech)
    if prac and letters.most_common(1)[0][1] > 6:
        errs.append(f"answers too often the same letter: {dict(letters)}")
    return errs


def check_labs(q, w, errs):
    for r in q.get("labs") or []:
        if not isinstance(r, list) or len(r) != 4 or r[3] not in ("H", "L", ""):
            errs.append(f"{w}: labs rows must be [test,value,range,flag]")
            return


def main():
    args = sys.argv[1:]
    write_index = "--write-index" in args
    if write_index:
        args = ["--all"]
    if args == ["--all"]:
        args = sorted(glob.glob(os.path.join(ROOT, "lessons", "*.json")))
        args = [a for a in args if not a.endswith(("index.json", "glossary.json"))]
    notes = load_notes()
    bad = 0
    passed = []
    for a in args:
        errs = check(a, notes)
        name = os.path.basename(a)
        if not errs:
            passed.append(os.path.basename(a)[:-5])
        if errs:
            bad += 1
            print(f"FAIL {name}")
            for e in errs:
                print("   -", e)
        else:
            print(f"OK   {name}")
    if write_index:
        with open(os.path.join(ROOT, "lessons", "index.json"), "w") as f:
            json.dump(sorted(passed), f)
        print(f"wrote lessons/index.json with {len(passed)} lessons")
        # one shared glossary from every passing lesson (used for hover definitions everywhere)
        gloss = {}
        for cid in sorted(passed):
            for term, de in (json.load(open(os.path.join(ROOT, "lessons", cid + ".json"), encoding="utf-8")).get("glossary") or {}).items():
                gloss.setdefault(term, de)
        with open(os.path.join(ROOT, "lessons", "glossary.json"), "w", encoding="utf-8") as f:
            json.dump(gloss, f, ensure_ascii=False, indent=0, sort_keys=True)
        print(f"wrote lessons/glossary.json with {len(gloss)} terms")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
