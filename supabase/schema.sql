-- Victor's Year 3 Notes: cloud save
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Safe to run more than once.

-- One row per student. `data` holds everything the app saves:
-- lesson progress, corrections, ticked conditions, practice arena scores and the
-- spaced-repetition (FSRS) schedule for blurts and exam-question retries.
create table if not exists public.year3_progress (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  username   text,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Row level security: a signed-in student can only ever see or change their own row.
alter table public.year3_progress enable row level security;

drop policy if exists "read own progress"   on public.year3_progress;
drop policy if exists "insert own progress" on public.year3_progress;
drop policy if exists "update own progress" on public.year3_progress;
drop policy if exists "delete own progress" on public.year3_progress;

create policy "read own progress"   on public.year3_progress for select using (auth.uid() = user_id);
create policy "insert own progress" on public.year3_progress for insert with check (auth.uid() = user_id);
create policy "update own progress" on public.year3_progress for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "delete own progress" on public.year3_progress for delete using (auth.uid() = user_id);

-- Keep updated_at current on every save.
create or replace function public.year3_touch() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists year3_touch on public.year3_progress;
create trigger year3_touch before update on public.year3_progress
  for each row execute function public.year3_touch();


-- ============================================================================================
-- Comments on questions and personal notes
-- (personal notes are saved inside each student's year3_progress row, like the rest of their work)
-- ============================================================================================

-- Rude-word check, no AI: the same word list the app uses (index.html, RUDE_ANY / RUDE_WHOLE).
-- Digits and symbols that stand in for letters are mapped back (0->o, 1->i, 3->e, 4->a, 5->s,
-- 7->t, 8->b, @->a, $->s; plain numbers like 455 are dropped first), punctuation is dropped, spaced-out letters ("f u c k") are joined,
-- and repeated letters ("fuuuck") still match. Medical words such as "spastic" are not on the list.
create or replace function public.year3_is_rude(t text) returns boolean
language plpgsql immutable as $$
declare s text;
begin
  s := regexp_replace(lower(coalesce(t, '')), '\m[0-9]+([.,][0-9]+)*\M', ' ', 'g');  -- plain numbers are never words
  s := translate(s, '0134578@$', 'oieastbas');
  s := regexp_replace(s, '[^a-z]+', ' ', 'g');
  s := regexp_replace(s, '\m([a-z]) (?=[a-z]\M)', '\1', 'g');
  return s ~ '(f+u+c+k+|f+c+k+|f+u+k+|p+h+u+c+k+|b+i+t+c+h+|b+i+a+t+c+h+|b+t+c+h+|w+a+n+k+|w+h+o+r+e+|n+i+g+g+e+r+|n+i+g+g+a+|b+o+l+l+o+c+k+|d+i+c+k+h+e+a+d+|a+s+s+h+o+l+e+|a+r+s+e+h+o+l+e+|d+u+m+b+a+s+s+|j+a+c+k+a+s+s+|m+o+t+h+e+r+f+|b+u+l+l+s+h+i+t+|s+h+i+t+h+e+a+d+)' or s ~ '\m(s+h+i+t+|s+h+i+t+s+|s+h+i+t+e+|s+h+i+t+t+y+|s+h+i+t+t+i+n+g+|c+u+n+t+|c+u+n+t+s+|t+w+a+t+|t+w+a+t+s+|a+s+s+|a+r+s+e+|a+r+s+e+s+|d+i+c+k+|d+i+c+k+s+|c+o+c+k+|c+o+c+k+s+|s+l+u+t+|s+l+u+t+s+|b+a+s+t+a+r+d+|b+a+s+t+a+r+d+s+|t+o+s+s+e+r+|t+o+s+s+e+r+s+|p+r+a+t+|i+d+i+o+t+|i+d+i+o+t+s+|m+o+r+o+n+|m+o+r+o+n+s+|i+m+b+e+c+i+l+e+|r+e+t+a+r+d+|r+e+t+a+r+d+s+|r+e+t+a+r+d+e+d+|s+p+a+z+|s+p+a+z+z+|k+y+s+|s+t+f+u+|g+t+f+o+|w+t+f+|p+a+k+i+|p+a+k+i+s+|c+h+i+n+k+|c+h+i+n+k+s+|k+i+k+e+|t+r+a+n+n+y+|t+r+a+n+n+i+e+s+|d+y+k+e+|d+y+k+e+s+|f+a+g+g+o+t+|f+a+g+g+o+t+s+|c+r+a+p+|p+i+s+s+o+f+f+|p+i+s+s+\s+o+f+f+|k+i+l+l+\s+y+o+u+r+s+e+l+f+|k+i+l+l+\s+u+r+s+e+l+f+|k+i+l+l+\s+y+o+u+r+\s+s+e+l+f+|g+o+\s+d+i+e+|s+h+u+t+\s+u+p+|s+h+u+t+\s+t+h+e+|s+c+r+e+w+\s+y+o+u+|s+c+r+e+w+\s+u+|y+o+u+\s+s+u+c+k+|u+\s+s+u+c+k+|f+\s+o+f+f+|e+f+f+\s+o+f+f+)\M';
end $$;

-- One row per comment. Everyone can read comments; only signed-in students can post.
-- `qkey` is condition | question ref | a short hash of the question text, so a comment stays
-- with its question even if the question files are rebuilt.
create table if not exists public.year3_comments (
  id         bigint generated always as identity primary key,
  qkey       text not null check (char_length(qkey) between 3 and 200),
  cond       text not null check (char_length(cond) between 1 and 120),
  body       text not null check (char_length(body) between 1 and 600),
  anonymous  boolean not null default false,
  author     text,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists year3_comments_qkey on public.year3_comments (qkey, created_at);

alter table public.year3_comments enable row level security;
drop policy if exists "read comments"       on public.year3_comments;
drop policy if exists "post own comments"   on public.year3_comments;
drop policy if exists "delete own comments" on public.year3_comments;
create policy "read comments"       on public.year3_comments for select using (true);
create policy "post own comments"   on public.year3_comments for insert with check (auth.uid() = user_id);
create policy "delete own comments" on public.year3_comments for delete using (auth.uid() = user_id);

-- Anonymous really means anonymous: nobody can read who wrote a comment (user_id is hidden),
-- only the name the student chose to show. Comments cannot be edited, only deleted by their author.
revoke all on public.year3_comments from anon, authenticated;
grant select (id, qkey, cond, body, author, created_at) on public.year3_comments to anon, authenticated;
grant insert (qkey, cond, body, anonymous) on public.year3_comments to authenticated;
grant delete on public.year3_comments to authenticated;

-- Every new comment: stamp who and when, fill in the name (or none if anonymous),
-- refuse rude ones, and stop floods (at most 30 comments an hour per student).
create or replace function public.year3_comment_in() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  if new.user_id is null then
    raise exception 'Log in to comment.' using errcode = '42501';
  end if;
  new.body := btrim(new.body);
  if new.body = '' then
    raise exception 'Write something first.' using errcode = '22023';
  end if;
  if public.year3_is_rude(new.body) then
    raise exception 'Please keep comments kind: that comment has words that are not allowed, so it was not posted.' using errcode = '22023';
  end if;
  if (select count(*) from public.year3_comments where user_id = new.user_id and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You have posted a lot of comments. Try again in a little while.' using errcode = '22023';
  end if;
  new.created_at := now();
  new.author := case when new.anonymous then null else coalesce(
    (select raw_user_meta_data ->> 'username' from auth.users where id = new.user_id),
    (select username from public.year3_progress where user_id = new.user_id),
    'A student') end;
  return new;
end $$;

drop trigger if exists year3_comment_in on public.year3_comments;
create trigger year3_comment_in before insert on public.year3_comments
  for each row execute function public.year3_comment_in();
