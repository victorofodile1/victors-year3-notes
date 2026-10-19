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

## 6. The full database and the Admin tab

`supabase/schema.sql` builds the whole database, not only the save table. Run it again whenever
it changes. It is safe to re-run and keeps every student's progress.

1. Supabase, **SQL Editor**, **New query**. Paste all of `supabase/schema.sql` and press **Run**.
2. Make yourself an admin. In a new query, put your own username in and press **Run**:

   ```sql
   update public.profiles set role = 'admin' where username = 'your-username';
   ```

3. Reload the app while logged in. An **Admin** tab appears (only for admins).

### What you can see

**In the app (Admin tab):**
- students, sign-ups, and active today / this week / this month;
- answers this week, average accuracy, and lessons finished;
- a 30-day chart of active students and sign-ups, plus accuracy by domain;
- a table of every student, sortable and searchable: joined, last active, active days, streak,
  lessons, answers, accuracy, open corrections, and spaced-repetition cards;
- **Download CSV** for a spreadsheet.

Tap a student to see:
- their full stats and a 60-day activity grid;
- their recent log ins and devices;
- a private note only admins see.

From there you can also reset their password, suspend or reactivate them, make them an admin,
or delete their account. Deleting asks you to type their username first.

**In Supabase:** **Table Editor**, then switch the schema dropdown from `public` to `admin`:

| View | What it shows |
| --- | --- |
| `admin.users` | One row per student with every stat |
| `admin.overview` | The headline numbers, plus database size |
| `admin.daily` | Each of the last 90 days: sign-ups, active students, answers |
| `admin.events` | Sign ups, log ins, app opens and log outs, newest first |
| `admin.audit` | Every admin action: who did it, to whom and when |

`supabase/admin_queries.sql` has ready-made queries, for example who joined this week, who
hasn't been back in 14 days, who may be struggling, and the weakest domain across everyone.

### What the database does

| Table | Holds | Written by |
| --- | --- | --- |
| `profiles` | Username, joined, last seen, log ins, device, role, status | The database (made automatically at sign-up) |
| `year3_progress` | The student's whole save | The app |
| `student_stats` | Numbers worked out from each save | The database, on every save |
| `daily_activity` | One row per student per day used | The database, on every save |
| `app_events` | Sign ups, log ins, app opens, log outs | The database (the app can only add opens and log outs, at most 120 an hour) |
| `admin_audit` | Admin actions | The admin functions |

### Security

- Row level security is on for every table:
  - a student can read only their own rows and write only their own save;
  - students cannot write stats, events or their own role;
  - logged-out visitors can read nothing.
- Admin powers are checked inside the database on every call, so hiding the tab is not what
  protects the data.
- The `admin` schema is not reachable through the public API at all.
- A suspended student can still log in, but nothing new saves.
- Each save is capped at 5 MB, so one account cannot fill the database.
- The tests in `supabase/tests` run the whole file on a real Postgres engine (PGlite). They cover
  every rule above, plus a run with 250 students. To re-run them:
  `cd supabase/tests && npm install && npm test`.

### Size

- 200+ students is small for Postgres. A typical save is 50–500 KB, so 250 students use roughly
  25–125 MB of the free plan's 500 MB.
- In the test, the admin list of 250 students loaded in about 15 ms, and a 450 KB save,
  including all its stats, took about 100 ms.
- The free plan pauses a project after a week with no activity at all. While students use the
  app it stays awake. If it ever pauses, press **Restore** in the dashboard.
- If the app outgrows the free plan, the Pro plan ($25/month) raises the database to 8 GB and
  never pauses.

Events older than a year can be cleared with `select public.prune_old_events();`.

## How saving works

- Every change is saved in the browser straight away (so it also works offline) and uploaded to
  Supabase about 1.5 seconds later, and again whenever the app is closed or hidden.
- When a student logs in on a device for the first time, the cloud copy is loaded. After that,
  whichever copy is newer wins.
- Anyone who made an account before cloud accounts were switched on just logs in with the same
  username and password on that device. The app moves the account and all its progress online
  automatically.
- There is no "forgot password" (no emails are sent). To reset a student's password, use the
  Admin tab in the app (tap the student, then **Reset password**). Or in Supabase,
  **Authentication**, then **Users**, find `theirusername@year3notes.app`, and use the menu to set
  a new password or delete the user.
- Free tier limits are far beyond what this needs (50,000 monthly active users, 500 MB database).
