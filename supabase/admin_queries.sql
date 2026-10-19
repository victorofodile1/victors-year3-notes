-- Handy queries for the Supabase SQL Editor. Run one at a time (highlight it, then Run).
-- Everything here only reads, except the last section, which is clearly marked.

-- Everyone who has joined, newest first
select username, display_name, cohort, joined_at, last_seen_at, active_days_7, streak_days,
       lessons_finished, answers_total, accuracy, corrections_open, status
  from admin.users
 order by joined_at desc;

-- Headline numbers
select * from admin.overview;

-- Day by day: sign-ups, active students and answers (last 90 days)
select * from admin.daily;

-- Who joined this week
select username, joined_at, last_device from admin.users
 where joined_at > now() - interval '7 days' order by joined_at desc;

-- Most active this week
select username, answers_7d, active_days_7, accuracy_7d from admin.users
 order by answers_7d desc limit 20;

-- Students who joined but have not been back for 14 days
select username, joined_at, last_seen_at, answers_total from admin.users
 where last_seen_at < now() - interval '14 days' or last_seen_at is null
 order by last_seen_at nulls first;

-- Students who may be struggling: plenty of answers, low accuracy
select username, answers_total, accuracy, domain_accuracy, corrections_open from admin.users
 where answers_total >= 50 and accuracy < 55 order by accuracy;

-- Weakest domain across everyone
select key as domain, round(avg(value::text::numeric), 1) as avg_accuracy, count(*) as students
  from public.student_stats, jsonb_each(domain_accuracy)
 group by key order by avg_accuracy;

-- Recent log ins and app opens
select * from admin.events limit 100;

-- Every admin action
select * from admin.audit;

-- Database size (the free plan allows 500 MB)
select database_size, progress_table_size from admin.overview;

-- Biggest saves
select username, save_kb from admin.users order by save_kb desc limit 10;


-- ===================== changes (these write to the database) =====================

-- Make someone an admin (do this once for yourself)
-- update public.profiles set role = 'admin' where username = 'your-username';

-- Reset a password (or use the Admin tab in the app)
-- update auth.users set encrypted_password = extensions.crypt('new-password', extensions.gen_salt('bf'))
--  where email = 'their-username@year3notes.app';

-- Suspend or reactivate (or use the Admin tab)
-- update public.profiles set status = 'suspended' where username = 'their-username';
-- update public.profiles set status = 'active'    where username = 'their-username';

-- Delete events older than a year
-- select public.prune_old_events();
