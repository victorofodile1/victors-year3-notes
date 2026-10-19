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
