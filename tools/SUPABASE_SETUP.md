# Turning on cloud accounts (Supabase)

Once this is done, students sign up with just a username and password. Everything they do is
saved to their account and appears on any device they log in on: lesson progress, quiz and
practice scores, corrections and notes, ticked conditions, practice arena results, and the
spaced-repetition schedule for blurts and question retries.

Until it is done, the app still works, but accounts and progress only live in one browser.

It takes about 5 minutes and is free.

## 1. Make a Supabase project

1. Go to <https://supabase.com> and sign in (you already have an account from the V-Taper app).
2. Click **New project**.
   - Name: `year3-notes`
   - Database password: press **Generate a password** (you will not need it again for this app)
   - Region: **West EU (Ireland)**
   - Plan: **Free**
3. Click **Create new project** and wait about a minute for it to finish.

(You could reuse the V-Taper project instead, but a separate project keeps the two apps apart.)

## 2. Create the table

1. In the left menu, open **SQL Editor**, then **New query**.
2. Open `supabase/schema.sql` from this project, copy all of it, paste it in, and press **Run**.
3. You should see "Success. No rows returned".

This makes one table, `year3_progress`, with one row per student, and switches on row level
security so each student can only ever read or change their own row.

## 3. Switch off email confirmation

Students never give a real email (the app quietly uses `username@year3notes.app`), so Supabase
must not wait for an email to be confirmed.

1. Left menu: **Authentication**, then **Sign In / Providers** (on older dashboards: **Providers**, then **Email**).
2. Make sure **Email** is enabled.
3. Turn **Confirm email** OFF and press **Save**.

## 4. Copy the two keys into the app

1. Left menu: **Project Settings** (the cog), then **API** (or **Data API** / **API Keys**).
2. Copy the **Project URL**, which looks like `https://abcdefgh.supabase.co`.
3. Copy the **anon / public** key (also called the **publishable** key; it is a long string).
   Do **not** copy the `service_role` / secret key. That one must never go in the app.
4. Paste both into chat for Claude, or put them in `index.html` yourself:

```js
const SUPABASE_URL = 'https://abcdefgh.supabase.co';
const SUPABASE_ANON_KEY = 'paste-the-anon-key-here';
```

The anon key is safe to be public. Row level security is what keeps the data private.

## 5. Check it works

1. Open the app (localhost or the live site) and press **Log in**, then **Create account**.
2. Make an account, open a lesson and answer a couple of questions.
3. Open the app on your phone, log in with the same username and password, and check that the
   progress is there.
4. In Supabase, **Table Editor**, then `year3_progress`, shows one row per student.

## How saving works

- Every change is saved in the browser straight away (so it also works offline) and uploaded to
  Supabase about 1.5 seconds later, and again whenever the app is closed or hidden.
- When a student logs in on a device for the first time, the cloud copy is loaded. After that,
  whichever copy is newer wins.
- Anyone who made an account before cloud accounts were switched on just logs in with the same
  username and password on that device. The app moves the account and all its progress online
  automatically.
- There is no "forgot password" (no emails are sent). To reset a student's password: Supabase,
  **Authentication**, then **Users**, find `theirusername@year3notes.app`, and use the menu to set
  a new password or delete the user.
- Free tier limits are far beyond what this needs (50,000 monthly active users, 500 MB database).

## Turning on comments (one-off, if your project was set up before comments existed)

Comments on questions need one extra table. Open **SQL Editor**, then **New query**, paste all of
`supabase/schema.sql` and press **Run** again. It is safe to re-run: your students' progress is not touched.

What it adds:

- `year3_comments`: one row per comment. Every student (and guests) can read comments; only
  logged-in students can post, and only the author can delete their own. Comments cannot be edited.
- Students choose to post with their username or anonymously. Nobody can read who wrote an
  anonymous comment, because the column that links a comment to an account is hidden from the app.
- Rude comments are refused automatically by a fixed word list (no AI), checked inside the database
  so it cannot be bypassed. Letter swaps (`sh1t`, `a$$`), spaced-out letters and repeated letters are
  caught. The list is checked against every note and question so medical words are never blocked.
  To change the list, edit it in both `supabase/schema.sql` (`year3_is_rude`) and `index.html`
  (`RUDE_ANY` / `RUDE_WHOLE`), then re-run the SQL.
- Each student can post at most 30 comments an hour.

Personal notes ("My notes") need nothing extra: they are saved in each student's existing progress row.
