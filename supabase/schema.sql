-- =====================================================================================
-- Victor's Year 3 Notes: full database
-- =====================================================================================
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- It is safe to run more than once, and it keeps every student's existing progress.
--
-- What it builds
--   public.profiles        one row per student: username, joined, last seen, role, status
--   public.year3_progress  everything the app saves for a student (lessons, answers, SRS ...)
--   public.student_stats   numbers worked out from that save: lessons, answers, accuracy ...
--   public.daily_activity  one row per student per day they used the app
--   public.app_events      sign ups, log ins and app opens
--   public.admin_audit     every admin action (suspend, reset password, delete ...)
--   admin.*                ready-made views for you: admin.users, admin.overview,
--                          admin.daily, admin.events, admin.audit (Table Editor > schema "admin")
--
-- Security
--   Row level security is on for every table. A student can only ever read their own rows
--   and can only write their own save. Stats, activity and events are written by the
--   database itself, never by the app. Admins (role = 'admin') can read everything through
--   the admin functions. The admin schema is not reachable through the public API at all.
--
-- Make yourself an admin (once, after running this file), replacing the username:
--   update public.profiles set role = 'admin' where username = 'your-username';
-- =====================================================================================

create extension if not exists pgcrypto with schema extensions;

-- -------------------------------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------------------------------

-- the app's day runs on UK time
create or replace function public.y3_today() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'Europe/London')::date
$$;

-- the app stores times as JavaScript milliseconds
create or replace function public.y3_ms(t timestamptz) returns bigint
language sql immutable set search_path = '' as $$
  select (extract(epoch from t) * 1000)::bigint
$$;

create or replace function public.y3_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- -------------------------------------------------------------------------------------
-- Profiles: one per student, made automatically when they sign up
-- -------------------------------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  username         text not null,
  display_name     text,
  cohort           text,
  role             text not null default 'student',
  status           text not null default 'active',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  last_sign_in_at  timestamptz,
  last_seen_at     timestamptz,
  sign_ins         integer not null default 0,
  last_device      text,
  admin_note       text
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_role_check') then
    alter table public.profiles add constraint profiles_role_check check (role in ('student', 'admin'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_status_check') then
    alter table public.profiles add constraint profiles_status_check check (status in ('active', 'suspended'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_username_check') then
    alter table public.profiles add constraint profiles_username_check check (username ~ '^[a-z0-9_.]{1,40}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_text_lengths') then
    alter table public.profiles add constraint profiles_text_lengths check (
      coalesce(length(display_name), 0) <= 60 and coalesce(length(cohort), 0) <= 40
      and coalesce(length(last_device), 0) <= 120 and coalesce(length(admin_note), 0) <= 1000);
  end if;
end $$;

create unique index if not exists profiles_username_key on public.profiles (lower(username));
create index if not exists profiles_created_idx   on public.profiles (created_at desc);
create index if not exists profiles_last_seen_idx on public.profiles (last_seen_at desc nulls last);

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.y3_touch();

-- is the signed-in user an active admin? (security definer so policies can call it
-- without looping back through row level security)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and status = 'active')
$$;

create or replace function public.is_suspended() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and status = 'suspended')
$$;

-- students may change their display name and cohort, nothing else
create or replace function public.profiles_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') and not public.is_admin() then
    if new.id <> old.id or new.username <> old.username or new.role <> old.role
       or new.status <> old.status or new.created_at <> old.created_at
       or new.sign_ins <> old.sign_ins or new.admin_note is distinct from old.admin_note
       or new.last_sign_in_at is distinct from old.last_sign_in_at
       or new.last_seen_at is distinct from old.last_seen_at then
      raise exception 'You can only change your display name and cohort.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

-- -------------------------------------------------------------------------------------
-- Progress: the student's whole save, one row each (this is what the app reads and writes)
-- -------------------------------------------------------------------------------------
create table if not exists public.year3_progress (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  username   text,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.year3_progress add column if not exists created_at timestamptz not null default now();
alter table public.year3_progress add column if not exists saves bigint not null default 0;

do $$ begin
  -- a save is normally well under 1 MB; this stops one account filling the database
  if not exists (select 1 from pg_constraint where conname = 'year3_progress_size') then
    alter table public.year3_progress add constraint year3_progress_size
      check (pg_column_size(data) <= 5 * 1024 * 1024) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'year3_progress_is_object') then
    alter table public.year3_progress add constraint year3_progress_is_object
      check (jsonb_typeof(data) = 'object') not valid;
  end if;
end $$;

create index if not exists year3_progress_updated_idx on public.year3_progress (updated_at desc);

create or replace function public.year3_progress_before() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.saves := 1;
  else
    new.created_at := old.created_at;
    new.saves := old.saves + 1;
  end if;
  return new;
end $$;

drop trigger if exists year3_touch on public.year3_progress;
drop trigger if exists year3_progress_before on public.year3_progress;
create trigger year3_progress_before before insert or update on public.year3_progress
  for each row execute function public.year3_progress_before();

-- -------------------------------------------------------------------------------------
-- Stats: worked out by the database from each save
-- -------------------------------------------------------------------------------------
create table if not exists public.student_stats (
  user_id              uuid primary key references auth.users (id) on delete cascade,
  lessons_started      integer not null default 0,
  lessons_finished     integer not null default 0,
  conditions_ticked    integer not null default 0,
  conditions_studied   integer not null default 0,
  answers_total        integer not null default 0,
  answers_7d           integer not null default 0,
  accuracy             numeric(5, 1),
  accuracy_7d          numeric(5, 1),
  domain_accuracy      jsonb not null default '{}'::jsonb,
  domain_answers       jsonb not null default '{}'::jsonb,
  bank_answers         integer not null default 0,
  arena_answers        integer not null default 0,
  arena_right          integer not null default 0,
  corrections_total    integer not null default 0,
  corrections_open     integer not null default 0,
  corrections_external integer not null default 0,
  srs_cards            integer not null default 0,
  srs_due              integer not null default 0,
  notes_read           integer not null default 0,
  notes_edited         integer not null default 0,
  data_bytes           integer not null default 0,
  last_active_at       timestamptz,
  computed_at          timestamptz not null default now()
);
create index if not exists student_stats_active_idx on public.student_stats (last_active_at desc nulls last);

create table if not exists public.daily_activity (
  user_id   uuid not null references auth.users (id) on delete cascade,
  day       date not null,
  saves     integer not null default 0,
  answers   integer not null default 0,
  first_at  timestamptz not null default now(),
  last_at   timestamptz not null default now(),
  primary key (user_id, day)
);
create index if not exists daily_activity_day_idx on public.daily_activity (day);

-- reads one save and returns its numbers
create or replace function public.y3_compute_stats(d jsonb)
returns public.student_stats
language plpgsql stable set search_path = '' as $$
declare
  s        public.student_stats;
  now_ms   bigint := public.y3_ms(now());
  week_ms  bigint := public.y3_ms(now() - interval '7 days');
  obj      jsonb;
begin
  s.domain_accuracy := '{}'::jsonb;
  s.domain_answers := '{}'::jsonb;

  -- lessons: {v, lessons:{id:{maxPos,total,...}}}
  obj := d #> '{progress,lessons}';
  if jsonb_typeof(obj) = 'object' then
    select count(*),
           count(*) filter (where (l.value->>'total') ~ '^\d+$' and (l.value->>'maxPos') ~ '^\d+$'
                             and (l.value->>'maxPos')::int >= greatest((l.value->>'total')::int - 1, 1))
      into s.lessons_started, s.lessons_finished
      from jsonb_each(obj) l;
  end if;

  -- conditions ticked as done: {id: ms}
  if jsonb_typeof(d->'ticks') = 'object' then
    select count(*) into s.conditions_ticked from jsonb_object_keys(d->'ticks');
  end if;

  -- every answer: ev = {cond: [[ms, domain, source, score 0..1], ...]}
  if jsonb_typeof(d->'ev') = 'object' then
    with e as (
      select c.key as cond,
             case when (x.value->>0) ~ '^\d+(\.\d+)?$' then (x.value->>0)::numeric::bigint end as at,
             x.value->>1 as dom,
             x.value->>2 as src,
             case when (x.value->>3) ~ '^-?\d+(\.\d+)?$' then least(greatest((x.value->>3)::numeric, 0), 1) end as score
        from jsonb_each(d->'ev') c,
             jsonb_array_elements(case when jsonb_typeof(c.value) = 'array' then c.value else '[]'::jsonb end) x
       where jsonb_typeof(x.value) = 'array'
    )
    select count(*),
           count(*) filter (where at >= week_ms),
           round(100 * avg(score), 1),
           round(100 * avg(score) filter (where at >= week_ms), 1),
           count(*) filter (where src = 'bank'),
           count(distinct cond)
      into s.answers_total, s.answers_7d, s.accuracy, s.accuracy_7d, s.bank_answers, s.conditions_studied
      from e;

    with e as (
      select x.value->>1 as dom,
             case when (x.value->>3) ~ '^-?\d+(\.\d+)?$' then least(greatest((x.value->>3)::numeric, 0), 1) end as score
        from jsonb_each(d->'ev') c,
             jsonb_array_elements(case when jsonb_typeof(c.value) = 'array' then c.value else '[]'::jsonb end) x
       where jsonb_typeof(x.value) = 'array'
    )
    select coalesce(jsonb_object_agg(dom, acc), '{}'::jsonb), coalesce(jsonb_object_agg(dom, n), '{}'::jsonb)
      into s.domain_accuracy, s.domain_answers
      from (select dom, round(100 * avg(score), 1) as acc, count(*) as n
              from e where dom is not null group by dom) g;
  end if;

  -- practice arena: {key: {n, right}}
  if jsonb_typeof(d->'arena') = 'object' then
    select coalesce(sum(case when (a.value->>'n') ~ '^\d+$' then (a.value->>'n')::int end), 0),
           coalesce(sum(case when (a.value->>'right') ~ '^\d+$' then (a.value->>'right')::int end), 0)
      into s.arena_answers, s.arena_right
      from jsonb_each(d->'arena') a
     where jsonb_typeof(a.value) = 'object';
  end if;

  -- corrections: [{fixed, src, ...}]
  if jsonb_typeof(d->'corr') = 'array' then
    select count(*),
           count(*) filter (where coalesce(c.value->>'fixed', 'false') <> 'true'),
           count(*) filter (where c.value->>'src' in ('Passmedicine', 'Quesmed', 'Other question bank', 'Teaching / lecture'))
      into s.corrections_total, s.corrections_open, s.corrections_external
      from jsonb_array_elements(d->'corr') c;
  end if;

  -- spaced repetition cards: {key: {due: ms, ...}}
  if jsonb_typeof(d->'srs') = 'object' then
    select count(*),
           count(*) filter (where (c.value->>'due') ~ '^\d+(\.\d+)?$' and (c.value->>'due')::numeric <= now_ms)
      into s.srs_cards, s.srs_due
      from jsonb_each(d->'srs') c;
  end if;

  if jsonb_typeof(d->'nread') = 'object' then
    select count(*) into s.notes_read from jsonb_object_keys(d->'nread');
  end if;
  if jsonb_typeof(d->'notes') = 'object' then
    select count(*) into s.notes_edited from jsonb_object_keys(d->'notes');
  end if;

  s.lessons_started    := coalesce(s.lessons_started, 0);
  s.lessons_finished   := coalesce(s.lessons_finished, 0);
  s.conditions_ticked  := coalesce(s.conditions_ticked, 0);
  s.conditions_studied := coalesce(s.conditions_studied, 0);
  s.answers_total      := coalesce(s.answers_total, 0);
  s.answers_7d         := coalesce(s.answers_7d, 0);
  s.bank_answers       := coalesce(s.bank_answers, 0);
  s.arena_answers      := coalesce(s.arena_answers, 0);
  s.arena_right        := coalesce(s.arena_right, 0);
  s.corrections_total  := coalesce(s.corrections_total, 0);
  s.corrections_open   := coalesce(s.corrections_open, 0);
  s.corrections_external := coalesce(s.corrections_external, 0);
  s.srs_cards          := coalesce(s.srs_cards, 0);
  s.srs_due            := coalesce(s.srs_due, 0);
  s.notes_read         := coalesce(s.notes_read, 0);
  s.notes_edited       := coalesce(s.notes_edited, 0);
  s.data_bytes         := pg_column_size(d);
  s.computed_at        := now();
  return s;
end $$;

-- after every save: refresh the student's stats, today's activity and last seen.
-- Any problem here is logged and skipped, so a save itself never fails because of stats.
create or replace function public.year3_progress_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  s          public.student_stats;
  today_ms   bigint := public.y3_ms((public.y3_today()::timestamp) at time zone 'Europe/London');
  answers_td integer := 0;
begin
  begin
    s := public.y3_compute_stats(new.data);
    s.user_id := new.user_id;
    s.last_active_at := now();

    insert into public.student_stats values (s.*)
    on conflict (user_id) do update set
      lessons_started = excluded.lessons_started, lessons_finished = excluded.lessons_finished,
      conditions_ticked = excluded.conditions_ticked, conditions_studied = excluded.conditions_studied,
      answers_total = excluded.answers_total, answers_7d = excluded.answers_7d,
      accuracy = excluded.accuracy, accuracy_7d = excluded.accuracy_7d,
      domain_accuracy = excluded.domain_accuracy, domain_answers = excluded.domain_answers,
      bank_answers = excluded.bank_answers, arena_answers = excluded.arena_answers,
      arena_right = excluded.arena_right, corrections_total = excluded.corrections_total,
      corrections_open = excluded.corrections_open, corrections_external = excluded.corrections_external,
      srs_cards = excluded.srs_cards, srs_due = excluded.srs_due, notes_read = excluded.notes_read,
      notes_edited = excluded.notes_edited, data_bytes = excluded.data_bytes,
      last_active_at = excluded.last_active_at, computed_at = excluded.computed_at;

    if jsonb_typeof(new.data->'ev') = 'object' then
      select count(*) into answers_td
        from jsonb_each(new.data->'ev') c,
             jsonb_array_elements(case when jsonb_typeof(c.value) = 'array' then c.value else '[]'::jsonb end) x
       where (x.value->>0) ~ '^\d+(\.\d+)?$' and (x.value->>0)::numeric >= today_ms;
    end if;

    insert into public.daily_activity as a (user_id, day, saves, answers, first_at, last_at)
    values (new.user_id, public.y3_today(), 1, answers_td, now(), now())
    on conflict (user_id, day) do update set
      saves = a.saves + 1, answers = greatest(a.answers, excluded.answers), last_at = now();

    update public.profiles set last_seen_at = now() where id = new.user_id;
  exception when others then
    raise warning 'year3 stats skipped for %: %', new.user_id, sqlerrm;
  end;
  return null;
end $$;

drop trigger if exists year3_progress_after on public.year3_progress;
create trigger year3_progress_after after insert or update of data on public.year3_progress
  for each row execute function public.year3_progress_after();

-- -------------------------------------------------------------------------------------
-- Events: sign ups, log ins and app opens
-- -------------------------------------------------------------------------------------
create table if not exists public.app_events (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users (id) on delete cascade,
  kind       text not null,
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'app_events_kind_check') then
    alter table public.app_events add constraint app_events_kind_check
      check (kind in ('sign_up', 'log_in', 'log_out', 'open', 'tour_done', 'error'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'app_events_meta_size') then
    alter table public.app_events add constraint app_events_meta_size check (pg_column_size(meta) <= 2048);
  end if;
end $$;
create index if not exists app_events_user_idx    on public.app_events (user_id, created_at desc);
create index if not exists app_events_created_idx on public.app_events (created_at desc);
create index if not exists app_events_kind_idx    on public.app_events (kind, created_at desc);

-- the app calls this; at most 120 events per student per hour are kept
create or replace function public.log_event(p_kind text, p_meta jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null or p_kind not in ('log_out', 'open', 'tour_done', 'error') then
    return;
  end if;
  if (select count(*) from public.app_events
       where user_id = uid and created_at > now() - interval '1 hour') >= 120 then
    return;
  end if;
  if p_meta is null or jsonb_typeof(p_meta) <> 'object' or pg_column_size(p_meta) > 2048 then
    p_meta := '{}'::jsonb;
  end if;
  insert into public.app_events (user_id, kind, meta) values (uid, p_kind, p_meta);
  if p_kind = 'open' and p_meta ? 'device' then
    update public.profiles
       set last_device = left(p_meta->>'device', 120), last_seen_at = now()
     where id = uid;
  end if;
end $$;

-- -------------------------------------------------------------------------------------
-- New accounts and log ins (triggers on Supabase's own auth.users table)
-- -------------------------------------------------------------------------------------
create or replace function public.y3_username_for(email text) returns text
language sql immutable set search_path = '' as $$
  select left(regexp_replace(lower(split_part(coalesce(email, ''), '@', 1)), '[^a-z0-9_.]', '_', 'g'), 40)
$$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  uname text := public.y3_username_for(new.email);
begin
  if uname = '' then uname := 'user_' || left(new.id::text, 8); end if;
  -- an old profile with the same name (from a deleted account) gets a suffix instead of blocking sign up
  if exists (select 1 from public.profiles where lower(username) = uname and id <> new.id) then
    uname := left(uname, 31) || '_' || left(new.id::text, 8);
  end if;
  insert into public.profiles (id, username, created_at)
  values (new.id, uname, coalesce(new.created_at, now()))
  on conflict (id) do nothing;
  insert into public.app_events (user_id, kind) values (new.id, 'sign_up');
  return new;
exception when others then
  raise warning 'year3 profile not made for %: %', new.id, sqlerrm;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.handle_user_sign_in() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.last_sign_in_at is distinct from old.last_sign_in_at and new.last_sign_in_at is not null then
    update public.profiles
       set last_sign_in_at = new.last_sign_in_at, sign_ins = sign_ins + 1, last_seen_at = now()
     where id = new.id;
    insert into public.app_events (user_id, kind) values (new.id, 'log_in');
  end if;
  return new;
exception when others then
  raise warning 'year3 sign in not logged for %: %', new.id, sqlerrm;
  return new;
end $$;

drop trigger if exists on_auth_user_sign_in on auth.users;
create trigger on_auth_user_sign_in after update of last_sign_in_at on auth.users
  for each row execute function public.handle_user_sign_in();

-- -------------------------------------------------------------------------------------
-- Admin audit log
-- -------------------------------------------------------------------------------------
create table if not exists public.admin_audit (
  id          bigint generated always as identity primary key,
  admin_id    uuid references auth.users (id) on delete set null,
  admin_name  text,
  action      text not null,
  target_id   uuid,
  target_name text,
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists admin_audit_created_idx on public.admin_audit (created_at desc);

create or replace function public.y3_audit(p_action text, p_target uuid, p_detail jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.admin_audit (admin_id, admin_name, action, target_id, target_name, detail)
  values (auth.uid(),
          (select username from public.profiles where id = auth.uid()),
          p_action, p_target,
          (select username from public.profiles where id = p_target),
          coalesce(p_detail, '{}'::jsonb));
end $$;

-- -------------------------------------------------------------------------------------
-- Row level security
-- -------------------------------------------------------------------------------------
alter table public.profiles       enable row level security;
alter table public.year3_progress enable row level security;
alter table public.student_stats  enable row level security;
alter table public.daily_activity enable row level security;
alter table public.app_events     enable row level security;
alter table public.admin_audit    enable row level security;

-- profiles: read and edit your own (the guard trigger limits which columns); admins read all
drop policy if exists "read own profile"    on public.profiles;
drop policy if exists "admins read profiles" on public.profiles;
drop policy if exists "update own profile"  on public.profiles;
create policy "read own profile"     on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy "admins read profiles" on public.profiles for select to authenticated using ((select public.is_admin()));
create policy "update own profile"   on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- progress: your own row only; a suspended student cannot save
drop policy if exists "read own progress"     on public.year3_progress;
drop policy if exists "insert own progress"   on public.year3_progress;
drop policy if exists "update own progress"   on public.year3_progress;
drop policy if exists "delete own progress"   on public.year3_progress;
drop policy if exists "admins read progress"  on public.year3_progress;
create policy "read own progress"    on public.year3_progress for select to authenticated using (user_id = (select auth.uid()));
create policy "admins read progress" on public.year3_progress for select to authenticated using ((select public.is_admin()));
create policy "insert own progress"  on public.year3_progress for insert to authenticated
  with check (user_id = (select auth.uid()) and not (select public.is_suspended()));
create policy "update own progress"  on public.year3_progress for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and not (select public.is_suspended()));
create policy "delete own progress"  on public.year3_progress for delete to authenticated using (user_id = (select auth.uid()));

-- stats, activity, events, audit: read only (the database writes them)
drop policy if exists "read own stats"      on public.student_stats;
drop policy if exists "admins read stats"   on public.student_stats;
create policy "read own stats"    on public.student_stats for select to authenticated using (user_id = (select auth.uid()));
create policy "admins read stats" on public.student_stats for select to authenticated using ((select public.is_admin()));

drop policy if exists "read own activity"    on public.daily_activity;
drop policy if exists "admins read activity" on public.daily_activity;
create policy "read own activity"    on public.daily_activity for select to authenticated using (user_id = (select auth.uid()));
create policy "admins read activity" on public.daily_activity for select to authenticated using ((select public.is_admin()));

drop policy if exists "admins read events" on public.app_events;
create policy "admins read events" on public.app_events for select to authenticated using ((select public.is_admin()));

drop policy if exists "admins read audit" on public.admin_audit;
create policy "admins read audit" on public.admin_audit for select to authenticated using ((select public.is_admin()));

-- table privileges: nothing for logged-out visitors; students get only what the policies allow
revoke all on public.profiles, public.year3_progress, public.student_stats,
              public.daily_activity, public.app_events, public.admin_audit from anon;
revoke all on public.profiles, public.student_stats, public.daily_activity, public.app_events, public.admin_audit from authenticated;
grant select, update (display_name, cohort) on public.profiles to authenticated;
grant select, insert, update, delete on public.year3_progress to authenticated;
grant select on public.student_stats, public.daily_activity, public.app_events, public.admin_audit to authenticated;

-- -------------------------------------------------------------------------------------
-- Admin views (Table Editor > schema "admin"). Not reachable through the public API.
-- -------------------------------------------------------------------------------------
create schema if not exists admin;
revoke all on schema admin from public, anon, authenticated;

create or replace view admin.streaks as
with days as (
  select user_id, day, day - (row_number() over (partition by user_id order by day))::int as grp
    from public.daily_activity
), runs as (
  select user_id, max(day) as last_day, count(*)::int as len from days group by user_id, grp
)
select distinct on (user_id) user_id,
       case when last_day >= public.y3_today() - 1 then len else 0 end as streak_days
  from runs
 order by user_id, last_day desc;

create or replace view admin.users as
select p.id,
       p.username,
       p.display_name,
       p.cohort,
       p.role,
       p.status,
       p.created_at                              as joined_at,
       p.last_sign_in_at,
       greatest(p.last_seen_at, s.last_active_at) as last_seen_at,
       p.sign_ins,
       p.last_device,
       coalesce(s.lessons_started, 0)            as lessons_started,
       coalesce(s.lessons_finished, 0)           as lessons_finished,
       coalesce(s.conditions_ticked, 0)          as conditions_ticked,
       coalesce(s.conditions_studied, 0)         as conditions_studied,
       coalesce(s.answers_total, 0)              as answers_total,
       coalesce(s.answers_7d, 0)                 as answers_7d,
       s.accuracy,
       s.accuracy_7d,
       s.domain_accuracy,
       coalesce(s.bank_answers, 0)               as bank_answers,
       coalesce(s.corrections_open, 0)           as corrections_open,
       coalesce(s.corrections_total, 0)          as corrections_total,
       coalesce(s.corrections_external, 0)       as corrections_external,
       coalesce(s.srs_cards, 0)                  as srs_cards,
       coalesce(s.srs_due, 0)                    as srs_due_at_last_save,
       coalesce(s.notes_read, 0)                 as notes_read,
       coalesce(s.notes_edited, 0)               as notes_edited,
       coalesce(st.streak_days, 0)               as streak_days,
       (select count(*)::int from public.daily_activity a
         where a.user_id = p.id and a.day > public.y3_today() - 7)  as active_days_7,
       (select count(*)::int from public.daily_activity a
         where a.user_id = p.id and a.day > public.y3_today() - 30) as active_days_30,
       round(coalesce(s.data_bytes, 0) / 1024.0, 1) as save_kb,
       p.admin_note
  from public.profiles p
  left join public.student_stats s on s.user_id = p.id
  left join admin.streaks st on st.user_id = p.id;

create or replace view admin.daily as
select g.day::date as day,
       (select count(*)::int from public.profiles p
         where (p.created_at at time zone 'Europe/London')::date = g.day::date) as sign_ups,
       (select count(*)::int from public.daily_activity a where a.day = g.day::date) as active_students,
       (select coalesce(sum(a.answers), 0)::int from public.daily_activity a where a.day = g.day::date) as answers,
       (select coalesce(sum(a.saves), 0)::int from public.daily_activity a where a.day = g.day::date) as saves,
       (select count(*)::int from public.profiles p
         where (p.created_at at time zone 'Europe/London')::date <= g.day::date) as total_students
  from generate_series(public.y3_today() - 89, public.y3_today(), interval '1 day') as g(day)
 order by 1 desc;

create or replace view admin.overview as
select (select count(*) from public.profiles)                                              as students,
       (select count(*) from public.profiles where role = 'admin')                         as admins,
       (select count(*) from public.profiles where status = 'suspended')                   as suspended,
       (select count(*) from public.profiles
         where (created_at at time zone 'Europe/London')::date = public.y3_today())        as joined_today,
       (select count(*) from public.profiles where created_at > now() - interval '7 days')  as joined_7d,
       (select count(*) from public.profiles where created_at > now() - interval '30 days') as joined_30d,
       (select count(distinct user_id) from public.daily_activity where day = public.y3_today())      as active_today,
       (select count(distinct user_id) from public.daily_activity where day > public.y3_today() - 7)  as active_7d,
       (select count(distinct user_id) from public.daily_activity where day > public.y3_today() - 30) as active_30d,
       (select coalesce(sum(answers_total), 0) from public.student_stats)                  as answers_total,
       (select coalesce(sum(answers_7d), 0) from public.student_stats)                     as answers_7d,
       (select round(avg(accuracy), 1) from public.student_stats where answers_total >= 10) as avg_accuracy,
       (select coalesce(sum(lessons_finished), 0) from public.student_stats)               as lessons_finished,
       (select coalesce(sum(corrections_external), 0) from public.student_stats)           as external_corrections,
       (select pg_size_pretty(pg_total_relation_size('public.year3_progress')))            as progress_table_size,
       (select pg_size_pretty(pg_database_size(current_database())))                       as database_size;

create or replace view admin.events as
select e.created_at, p.username, e.kind, e.meta
  from public.app_events e
  left join public.profiles p on p.id = e.user_id
 order by e.created_at desc;

create or replace view admin.audit as
select created_at, admin_name, action, target_name, detail
  from public.admin_audit
 order by created_at desc;

-- -------------------------------------------------------------------------------------
-- Admin functions (used by the Admin tab in the app; each one checks you are an admin)
-- -------------------------------------------------------------------------------------
create or replace function public.y3_require_admin() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
end $$;

create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  perform public.y3_require_admin();
  select jsonb_build_object(
           'totals', (select to_jsonb(o) from admin.overview o),
           'daily',  (select coalesce(jsonb_agg(to_jsonb(d) order by d.day), '[]'::jsonb)
                        from (select * from admin.daily where day > public.y3_today() - 30) d),
           'domains', (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
                         select x.key as k, round(avg(x.value::text::numeric), 1) as v
                           from public.student_stats s, jsonb_each(s.domain_accuracy) x
                          where jsonb_typeof(x.value) = 'number'
                          group by x.key) dd))
    into r;
  return r;
end $$;

create or replace function public.admin_list_users() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  perform public.y3_require_admin();
  select coalesce(jsonb_agg(to_jsonb(u) order by u.joined_at desc), '[]'::jsonb) into r from admin.users u;
  return r;
end $$;

create or replace function public.admin_user_detail(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  perform public.y3_require_admin();
  select jsonb_build_object(
           'user', (select to_jsonb(u) from admin.users u where u.id = p_user),
           'days', (select coalesce(jsonb_agg(to_jsonb(a) order by a.day desc), '[]'::jsonb)
                      from (select day, saves, answers, first_at, last_at from public.daily_activity
                             where user_id = p_user and day > public.y3_today() - 60) a),
           'events', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc), '[]'::jsonb)
                        from (select created_at, kind, meta from public.app_events
                               where user_id = p_user order by created_at desc limit 50) e))
    into r;
  return r;
end $$;

create or replace function public.admin_set_status(p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.y3_require_admin();
  if p_user = auth.uid() then raise exception 'You cannot change your own status.'; end if;
  if p_status not in ('active', 'suspended') then raise exception 'Status must be active or suspended.'; end if;
  update public.profiles set status = p_status where id = p_user;
  perform public.y3_audit('set_status', p_user, jsonb_build_object('status', p_status));
end $$;

create or replace function public.admin_set_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.y3_require_admin();
  if p_user = auth.uid() then raise exception 'You cannot change your own role.'; end if;
  if p_role not in ('student', 'admin') then raise exception 'Role must be student or admin.'; end if;
  update public.profiles set role = p_role where id = p_user;
  perform public.y3_audit('set_role', p_user, jsonb_build_object('role', p_role));
end $$;

create or replace function public.admin_set_note(p_user uuid, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.y3_require_admin();
  update public.profiles set admin_note = left(nullif(trim(p_note), ''), 1000) where id = p_user;
  perform public.y3_audit('set_note', p_user);
end $$;

-- students never give an email, so this is how a forgotten password is reset
create or replace function public.admin_reset_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.y3_require_admin();
  if length(coalesce(p_password, '')) < 6 then raise exception 'Password must be at least 6 characters.'; end if;
  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_user;
  if not found then raise exception 'No such student.'; end if;
  perform public.y3_audit('reset_password', p_user);
end $$;

-- deletes the account and everything saved for it
create or replace function public.admin_delete_user(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare uname text;
begin
  perform public.y3_require_admin();
  if p_user = auth.uid() then raise exception 'You cannot delete your own account here.'; end if;
  select username into uname from public.profiles where id = p_user;
  perform public.y3_audit('delete_user', p_user, jsonb_build_object('username', uname));
  delete from auth.users where id = p_user;
end $$;

-- a student can delete their own account and all their data
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- old events are cleared after a year (run by hand, or schedule it; see SUPABASE_SETUP.md)
create or replace function public.prune_old_events() returns integer
language sql security definer set search_path = '' as $$
  with d as (delete from public.app_events where created_at < now() - interval '365 days' returning 1)
  select count(*)::int from d
$$;

-- function privileges: nobody by default, then only what the app needs
-- (triggers and the admin views run as the database owner, so they need no grants)
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.is_admin()                       to authenticated;
grant execute on function public.is_suspended()                   to authenticated;
grant execute on function public.log_event(text, jsonb)           to authenticated;
grant execute on function public.delete_my_account()              to authenticated;
grant execute on function public.admin_overview()                 to authenticated;
grant execute on function public.admin_list_users()               to authenticated;
grant execute on function public.admin_user_detail(uuid)          to authenticated;
grant execute on function public.admin_set_status(uuid, text)     to authenticated;
grant execute on function public.admin_set_role(uuid, text)       to authenticated;
grant execute on function public.admin_set_note(uuid, text)       to authenticated;
grant execute on function public.admin_reset_password(uuid, text) to authenticated;
grant execute on function public.admin_delete_user(uuid)          to authenticated;

-- functions made after this file runs should not be callable by the public API by default
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- -------------------------------------------------------------------------------------
-- Backfill: profiles and stats for everyone who signed up before this file was run
-- -------------------------------------------------------------------------------------
insert into public.profiles (id, username, created_at, last_sign_in_at, sign_ins)
select u.id,
       case when exists (select 1 from public.profiles p2 where lower(p2.username) = public.y3_username_for(u.email))
            then left(public.y3_username_for(u.email), 31) || '_' || left(u.id::text, 8)
            else coalesce(nullif(public.y3_username_for(u.email), ''), 'user_' || left(u.id::text, 8)) end,
       u.created_at, u.last_sign_in_at,
       case when u.last_sign_in_at is null then 0 else 1 end
  from auth.users u
 where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;

do $$
declare
  g record;
  s public.student_stats;
begin
  for g in select user_id, data, updated_at from public.year3_progress loop
    s := public.y3_compute_stats(g.data);
    s.user_id := g.user_id;
    s.last_active_at := g.updated_at;
    insert into public.student_stats values (s.*) on conflict (user_id) do nothing;
  end loop;
end $$;

update public.profiles p
   set last_seen_at = g.updated_at
  from public.year3_progress g
 where g.user_id = p.id and p.last_seen_at is null;

insert into public.daily_activity (user_id, day, saves, answers, first_at, last_at)
select user_id, (updated_at at time zone 'Europe/London')::date, 1, 0, updated_at, updated_at
  from public.year3_progress
on conflict (user_id, day) do nothing;

-- tell the API about the new tables and functions
notify pgrst, 'reload schema';
