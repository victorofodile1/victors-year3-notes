# Notes visuals format (`notesvis/<condition-id>.json`)

The Notes tab shows each condition as a step-through: Diagnosis, Investigation, Management,
Science, then Test yourself. The note points are revealed a few at a time with Next. This file adds
the visual aids shown between the points, plus extra hover definitions, so the notes are easy to
take in.

Check a file with `python3 tools/check_notesvis.py notesvis/<id>.json`.

```json
{
  "id": "diabetic-ketoacidosis",
  "visuals": [
    { "d": "diagnosis", "after": 0, "type": "visual", "title": "Where DKA hits", "text": "Optional caption, max 30 words.",
      "visual": { "kind": "organ", "organs": ["pancreas", "kidneys", "brain"] } },
    { "d": "science", "after": 1, "type": "flow", "title": "Why ketones build up",
      "nodes": ["No insulin", "Lipolysis", "Fatty acids to the liver", "Ketones", "Acidosis"] },
    { "d": "investigation", "after": 0, "type": "compare", "title": "DKA vs HHS",
      "head": ["", "DKA", "HHS"], "rows": [["Onset", "Hours", "Days"]] }
  ],
  "glossary": { "Ketonaemia": "Ketones in the blood.", "Lipolysis": "Breakdown of stored fat into fatty acids." }
}
```

- `d` + `after`: the visual appears right after note subsection `after` (the `src` index) in domain `d`.
- `type`: `visual` (with a `visual` object), `flow` (3 to 7 `nodes`), or `compare` (`head`, `rows`).
- Visual kinds: everything in `LESSON_FORMAT.md` (ecg, cxr, scale, trend, abdomen, coronary) plus:
  - `organ`: `organs` from brain, eyes, ears, sinuses, throat, thyroid, oesophagus, breast, lungs, heart,
    aorta, liver, gallbladder, stomach, spleen, pancreas, kidneys, bowel, bladder, pelvic (prostate or
    uterus), testes, spine, joints, skin, blood, lymph, nerves. Highlights them on a body diagram.
  - `cycle`: `steps` (3 to 6, each max 40 characters) and optional `centre`. A vicious circle or loop.
  - `tree`: `root` and `children` (2 to 5) of `{label, items:[...]}`. Classifications and types.
  - `timeline`: `events` (2 to 8) of `{t, x}`. Time course, onset, treatment windows.
  - `keyfacts`: `facts` (2 to 6) of `{big, label}`, `big` max 14 characters. Cut-offs and numbers to learn.

## Rules (checked)

- 6 to 14 visuals per condition, at least 1 in every domain that has notes, and at least 3 in Science
  when it has 3 or more subsections (otherwise at least 1 per Science subsection). Science should be the
  most visual: mechanisms as flows and cycles, anatomy as organ maps.
- Use at least 3 different kinds of visual per condition.
- Do not repeat what is already in the notes in a duller way: each visual must make a point easier to
  understand or remember (a mechanism, a comparison, a sequence, where it is, the numbers).
- Facts must agree with the notes.
- `glossary`: every term in this condition's notes that a Year 3 student might not know, that is not
  already in the lesson's glossary: medical words, signs, eponyms, drugs, scores, abbreviations, Latin.
  Aim to cover every such term (often 30 to 100). One plain sentence each, max 25 words.
