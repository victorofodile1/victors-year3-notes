# Lesson file format (`lessons/<condition-id>.json`)

One file per condition. The app loads it when a student opens "Learn" for that condition.
The original notes (in `index.html`) are the source of truth: lessons **reference** note
subsections by index (`"src"`), and the app prints those note points word-for-word. The lesson
adds the patient context, decisions, flow diagrams and questions around them.

Run the checker after writing a file:

```
python3 tools/check_lesson.py lessons/<id>.json
```

## Top level

```json
{
  "id": "diabetic-ketoacidosis",
  "patient": {
    "name": "Amira Hassan",
    "age": 19,
    "sex": "F",
    "setting": "Emergency Department",
    "complaint": "Vomiting, abdominal pain and drowsiness for 24 hours",
    "background": ["Type 1 diabetes since age 11", "Recent gastroenteritis"]
  },
  "domains": {
    "diagnosis":     { "exam": "...", "steps": [ ... ] },
    "investigation": { "exam": "...", "steps": [ ... ] },
    "management":    { "exam": "...", "steps": [ ... ] },
    "science":       { "exam": "...", "steps": [ ... ] }
  },
  "mcq":       [ ... 8 to 10 quick recall questions ... ],
  "blurt":     { ... quick free-recall questions, in rounds ... },
  "glossary":  { ... term: one-line definition, shown when hovering a word ... },
  "technique": [ ... exactly 4 worked exam questions, one per domain ... ],
  "practice":  [ ... exactly 12 exam questions in the exam's domain mix ... ]
}
```

- `patient` is ONE patient followed through all four domains, like a real admission.
  Use realistic, varied London names. Ages/sex must fit the condition's epidemiology.
- `exam` (per domain): one or two sentences on how this domain is asked in the exam for this
  condition, e.g. "Expect 'Which is the most likely diagnosis?' with a vignette of polyuria,
  vomiting and Kussmaul breathing."

## Steps (inside each domain)

Each step is one screen the student moves through with **Next**. Aim for 6 to 14 steps per domain.
Every step object has a `type`:

| type | fields | use |
|---|---|---|
| `story` | `points` (2 to 5 short bullets, max 15 words each), optional `vitals` `{T,HR,BP,RR,SpO2,GCS,CBG}` (any subset, strings) | What happens to the patient next, as bullets. No paragraphs. |
| `labs` | `title`, `rows`: `[[test, value, range, flag]]` (flag `"H"`, `"L"` or `""`), optional `text` (max 25 words) | A results panel. Use real units and realistic values. |
| `ask` | `q`, `o` (3 to 5 options), `a` (index of correct), `r` (reason, 1 to 2 sentences) | A decision point in the case. The student must pick before moving on. |
| `notes` | `src` (index of the note subsection in this domain, or `"guidelines"`), `lead` | Shows the original note subsection word-for-word. `lead` is 1 or 2 short sentences (max 35 words) tying it to THIS patient ("Amira's bicarbonate of 9 is why..."). |
| `flow` | `title`, `nodes` (3 to 7 short strings), optional `caption` | Animated step-by-step flow diagram (pathway, algorithm, mechanism). |
| `compare` | `title`, `head` (column headings), `rows` (array of arrays) | Side-by-side table (e.g. DKA vs HHS). |
| `visual` | `visual` (see Visuals), optional `text` | A drawn ECG, chest X-ray, scale, trend chart, abdomen map or coronary map. |
| `pearl` | `text` | High-yield exam point. |
| `trap` | `text` | Common mistake / distractor to avoid. |

**Visual rule (checked):** at least 3 `visual` steps across the four domains. Use them wherever the
condition has something to SEE or a number to place: the ECG, the X-ray, where the pain is, where a value
sits against its range, how values change over time.

**Coverage rule (checked):** in each domain, every note subsection index `0..n-1` must appear in
exactly one `notes` step. If the condition has `guidelines`, one `notes` step with
`"src":"guidelines"` must appear (put it in management unless another domain fits better).
Order the `notes` steps so the story flows; they do not have to be in index order.

Write `**bold**` for emphasis in any text field. No HTML.

**Keep it short (checked).** Students zone out on paragraphs. Story steps are bullets, not prose.
`lead`, `text`, `caption`, `r`, technique/practice step `x` and blurt `why` stay under about 35 to 45 words.

## `mcq` (quick recall, 8 to 10)

```json
{ "d": "diagnosis", "q": "Short recall question?", "o": ["A", "B", "C", "D"], "a": 2, "r": "One-line reason." }
```
`d` is one of `diagnosis`, `investigation`, `management`, `science`. 4 options. Base these on the
notes and the existing `recall` items. Cover all four domains.

## `technique` (exactly 4, one per domain, in domain order)

A full exam-style SBA, then a broken-down method for cracking it.

```json
{
  "d": "diagnosis",
  "stem": "A 19 year old woman has a 24 hour history of vomiting and abdominal pain. ...",
  "labs": [["pH", "7.12", "7.35–7.45", "L"]],
  "q": "Which is the most likely diagnosis?",
  "o": ["...", "...", "...", "...", "..."],
  "a": 1,
  "steps": [
    { "t": "Read the question line first", "x": "It asks for a diagnosis, so..." },
    { "t": "Pick out the clues", "clues": ["24 hour history", "type 1 diabetes"], "x": "Why each clue matters." },
    { "t": "Make your own answer before looking", "x": "..." },
    { "t": "Rule out the others", "elim": [[0, "why A is wrong"], [2, "why C is wrong"], [3, "..."], [4, "..."]] },
    { "t": "Commit", "x": "Answer and the one-line rule to remember." }
  ]
}
```
- `clues` must be exact substrings of `stem` (the app highlights them).
- `elim` must cover every wrong option index.

## Visuals (`visual` object, used in `visual` steps and optionally on any `technique`, `practice` or `blurt` question)

The app draws these; you only describe them. Pick the `kind`:

```json
{ "kind": "ecg", "title": "12-lead ECG on arrival", "layout": "12lead", "rhythm": "sinus", "rate": 48,
  "leads": { "II": "st_elev", "III": "st_elev", "aVF": "st_elev", "I": "st_dep", "aVL": "st_dep" },
  "caption": "ST elevation in II, III, aVF with reciprocal depression in I and aVL: inferior STEMI." }
```
- `layout`: `"12lead"` (grid of all 12 leads plus a lead II rhythm strip) or `"strip"` (one rhythm strip, lead II).
- `rhythm`: `sinus`, `sinus_brady`, `sinus_tachy`, `af`, `flutter`, `svt`, `vt`, `vf`, `asystole`, `first_degree`, `mobitz1`, `mobitz2`, `chb` (complete heart block).
- `leads` patterns (unlisted leads are normal): `normal`, `st_elev`, `st_dep`, `t_inv`, `q_wave`, `peaked_t`, `flat_t`.

```json
{ "kind": "cxr", "title": "Chest X-ray", "findings": [ { "type": "consolidation", "side": "left", "zone": "lower" } ],
  "caption": "Left lower zone consolidation." }
```
- `type`: `consolidation`, `effusion`, `pneumothorax`, `mass`, `cavity`, `cardiomegaly`, `hilar`, `free_air`, `fibrosis`, `pulm_oedema`.
- `side`: `left`, `right` or `both` (from the PATIENT's point of view; the app draws it radiologically). `zone`: `upper`, `middle`, `lower` (ignored for cardiomegaly, free_air, pulm_oedema).

```json
{ "kind": "scale", "title": "Venous pH", "min": 6.9, "max": 7.6, "unit": "",
  "bands": [[6.9, 7.0, "severe", "bad"], [7.0, 7.3, "acidosis", "warn"], [7.35, 7.45, "normal", "ok"]],
  "value": 7.14, "label": "Chloe 7.14", "caption": "Below 7.3 confirms acidosis." }
```
`bands` are `[from, to, label, tone]` with tone `ok`, `warn` or `bad`. Use for pH, potassium, CURB-65, GCS, scores.

```json
{ "kind": "trend", "title": "First 12 hours", "x": ["0 h", "2 h", "6 h", "12 h"], "unit": "mmol/L",
  "series": [ { "name": "Glucose", "values": [31, 22, 14, 9] }, { "name": "Ketones", "values": [5.2, 4.1, 2.0, 0.4] } ],
  "caption": "Ketones, not glucose, tell you DKA is resolving." }
```
1 to 3 series, same length as `x`. Use for troponin curves, treatment response, falling Hb.

```json
{ "kind": "abdomen", "title": "Where the pain is", "regions": ["RUQ", "epigastric"], "caption": "..." }
```
Regions: `RUQ`, `epigastric`, `LUQ`, `R_flank`, `umbilical`, `L_flank`, `RIF`, `suprapubic`, `LIF`.

```json
{ "kind": "coronary", "title": "Culprit artery", "artery": "RCA", "caption": "..." }
```
`artery`: `RCA`, `LAD`, `Cx`, `LMS`.

## `blurt` (quick free-recall questions, no case)

No patient and no vignette: just short questions. The student types (or dictates) everything they
remember for each one, checks it, sees what they missed and the extra detail that wins exam marks, and
repeats in rounds until they get everything.

```json
{
  "prompts": [
    { "d": "diagnosis",
      "q": "What are the three parts of the DKA diagnostic triad, with the cut-offs?",
      "tip": "Exam thinking: you need all three. If one is missing, the answer is not DKA.",
      "points": [
        { "p": "Glucose above 11 mmol/L (or known diabetes)", "k": [["glucose", "sugar", "cbg"], ["11"]], "why": "Euglycaemic DKA exists (SGLT2 inhibitors), so a normal glucose does not exclude it." },
        { "p": "Ketones above 3 mmol/L", "k": [["ketone"], ["3", "three"]], "why": "..." }
      ] }
  ]
}
```
- **8 to 12 prompts**, short and direct (one line each), in domain order, matching the exam mix:
  about half diagnosis-type (classic presentation, key features, distinguishing it from its
  differentials, red flags, complications), then investigation, management, and 1 or 2 science.
- Together the prompts must test ALL the key content of the condition, framed the way the exam makes
  you think: "What is the first-line investigation and what does it show?", "What is the next step if
  X fails?", "Which feature tells you it is A rather than B?", "Why does X cause Y?".
- 2 to 6 `points` per prompt. `p` is the model answer line shown after checking.
- `k` keyword groups: the point counts as recalled when EVERY group has one of its alternatives in the
  answer (case-insensitive; alternatives of 3 letters or fewer must match as whole words). Be generous:
  abbreviations, spellings, phrasings. Avoid alternatives that appear inside other words.
- `why`: one short sentence of extra exam information (a threshold, a distractor, the reason).

## `glossary` (hover definitions)

```json
"glossary": { "Kussmaul breathing": "Deep, laboured breathing that blows off CO2 to compensate for metabolic acidosis.",
              "Anion gap": "(Na + K) minus (Cl + HCO3); a raised gap means extra unmeasured acid such as ketones." }
```
- 25 to 60 terms that a Year 3 student might not know or might mix up, taken from THIS condition's
  notes and lesson: medical terms, signs, eponyms, scores, drug names, abbreviations.
- Keys are written exactly as they usually appear in the text (the app matches them case-insensitively,
  whole words). Prefer the shortest common form ("GCS" rather than "Glasgow Coma Scale score").
- Definitions: one plain-English sentence, max 25 words, no HTML.

## `practice` (exactly 12, in the exam's domain mix)

**Every practice question tests THIS condition.** The correct answer must always be this condition
or something about it: the diagnosis itself or a named subtype, a feature, finding, severity, cause,
precipitant, complication, test, result, treatment step or mechanism of THIS condition. Other
conditions may appear only as wrong options (distractors). Never write a question whose answer is a
different condition (no "it's actually HHS" or "it's actually aortic dissection" questions).

**Every practice question has `steps`**, the full thinking process, in exactly the same shape as
`technique` steps (read the question line, pick out the `clues` (exact substrings of the stem), make
your own answer, `elim` every wrong option with a reason, commit). The app plays this through,
animated, when the student gets it wrong (or asks to see it).

The real papers (482 questions checked) are about 51% diagnosis, 27% management, 16% investigation
and 6% science. So the 12 practice questions are: **6 diagnosis, 2 investigation, 3 management, 1 science**,
in that order. Diagnosis-type includes "most likely diagnosis", "most likely finding on examination /
spirometry / ECG", and "most likely cause". Also match the papers' pattern:
- About a third of stems include an observations sentence and about a third include an
  "Investigations:" block with reference ranges. At least 4 of the 12 must have observations and at
  least 3 must have `labs`.
- If the condition has an ECG, X-ray or other image finding, at least one practice question uses a
  `visual` ("ECG (see item resources)" in the stem).
- Stems are about 40 to 80 words.

```json
{ "d": "management", "stem": "...", "labs": [], "visual": null, "q": "Which is the most appropriate initial management?",
  "o": ["...", "...", "...", "...", "..."], "a": 3, "e": "One or two sentences: why the answer is right and the key distractor is wrong.",
  "steps": [ { "t": "Read the question line first", "x": "..." }, { "t": "Pick out the clues", "clues": ["..."], "x": "..." },
             { "t": "Make your own answer before looking", "x": "..." }, { "t": "Rule out the others", "elim": [[0, "..."], [1, "..."], [2, "..."], [4, "..."]] },
             { "t": "Commit", "x": "..." } ] }
```

## Exam style (Imperial Phase 1c EFA / formative SBAs)

- Single best answer, **5 options A to E**, options short and **alphabetical**.
- Stems: "A 58 year old man has ..." with history, observations ("His temperature is 37.2°C,
  pulse rate 112 bpm, BP 78/56 mmHg, respiratory rate 22 breaths per minute and oxygen
  saturation 95% breathing air."), then optional "Investigations:" with value and reference range.
- Lead-ins used by the real papers: "Which is the most likely diagnosis?", "Which is the most
  appropriate initial investigation?", "Which is the most appropriate diagnostic investigation?",
  "Which is the next most appropriate step in management?", "Which is the most appropriate
  initial management?", "Which is the most likely causative organism?", "Which is the most likely
  mechanism...?", "Which is the most likely finding on ...?", "Which is the mode of inheritance?".
- Science questions are applied: mechanism, organism, pathophysiology, inheritance, drug action,
  explaining a finding in the vignette.
- Optimise for **high yield**: the classic presentation, the gold-standard and first-line test,
  first-line treatment, emergency steps, and the classic distractors.
- Facts must agree with the notes. Do not invent facts that contradict them. Standard UK practice
  (NICE) only where the notes are silent.
- Vary which option is correct; never the same letter for most questions.
