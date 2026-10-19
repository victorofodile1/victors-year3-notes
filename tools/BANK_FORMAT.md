# Question bank format (`bank/<condition-id>.json`)

A large bank of exam-style single best answer questions for one condition, separate from the
12 practice questions inside the lesson. Together the questions must examine ALL of the
condition's notes, so a student who gets through the bank has been tested on everything.

Check a file with:

```
python3 tools/check_bank.py bank/<id>.json
```

## Shape

```json
{
  "id": "diabetic-ketoacidosis",
  "questions": [
    {
      "d": "diagnosis",
      "covers": [["diagnosis", 1, [0, 2]], ["science", 3, [1]]],
      "stem": "A 19 year old woman with type 1 diabetes has vomited for 24 hours. ...",
      "labs": [["pH (venous)", "7.12", "7.35–7.45", "L"]],
      "visual": null,
      "q": "Which is the most likely diagnosis?",
      "o": ["...", "...", "...", "...", "..."],
      "a": 2,
      "e": "One or two sentences: why the answer is right and the key distractor is wrong.",
      "steps": [
        { "t": "Pick out the clues", "clues": ["exact text from the stem"], "x": "..." },
        { "t": "Rule out the others", "elim": [[0, "why wrong"], [1, "..."], [3, "..."], [4, "..."]] },
        { "t": "Commit", "x": "The answer, and the rule to remember." }
      ]
    }
  ]
}
```

- `d`: the domain the question is asked in (`diagnosis`, `investigation`, `management`, `science`).
- `covers`: which note points the question examines. Each entry is
  `[domain, subsection index, [point indexes]]`, using the `src` numbers in the source notes file.
  A question may cover points from more than one subsection.
- `stem`, `labs`, `visual`, `q`, `o`, `a`, `e`: exactly as practice questions in `LESSON_FORMAT.md`
  (5 options, alphabetical, real exam lead-ins, stems about 40 to 80 words, observations and labs
  where they fit, a `visual` such as an ECG or chest X-ray where the finding is visual).
- `steps`: the thinking process shown when a student gets it wrong: at least 3 steps, one with
  `clues` (exact substrings of the stem) and one with `elim` covering every wrong option.

## Rules (checked)

- **Size:** twice the number of note subsections, at least 24 and at most 45 questions.
- **Coverage:** every note subsection in every domain is covered by at least one question, and at
  least 75% of all individual note points appear in some question's `covers`. Guidelines are
  covered by naming them in a stem, option or explanation where relevant.
- **Mix:** at least 35% diagnosis-type questions, and at least 3 questions in each of
  diagnosis, investigation and management and at least 2 in science (if those domains have notes).
- **About this condition only:** every correct answer is this condition or something about it.
  Other conditions only appear as distractors.
- **New questions:** do not repeat the lesson's practice or technique questions.
- **Variety:** vary the correct letter; no letter is the answer for more than 30% of questions.
  Vary the patient, setting and lead-in; test the same point from different angles (a finding,
  the next step, the mechanism, the complication, the distractor that is commonly confused).
