import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'fs';

// usage: node schema_test.mjs schema.sql old_schema.sql [admin_queries.sql]
const schema = fs.readFileSync(process.argv[2], 'utf8');
const db = new PGlite({ extensions: { pgcrypto } });
let fails = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); if (!c) fails++; };
const q = async (s, p) => (await db.query(s, p)).rows;
const expectErr = async (fn, m) => { try { await fn(); ok(false, m + ' (no error)'); } catch (e) { ok(true, m + ' -> ' + e.message.split('\n')[0]); } };

// ---- a mock of the parts of Supabase the schema relies on ----
await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  create role supabase_auth_admin nologin;
  create schema auth; create schema extensions;
  grant usage on schema public to anon, authenticated, service_role;
  grant usage on schema auth to anon, authenticated;
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  create table auth.users (id uuid primary key default gen_random_uuid(), email text unique, encrypted_password text,
    raw_user_meta_data jsonb default '{}', created_at timestamptz default now(), updated_at timestamptz default now(),
    last_sign_in_at timestamptz);
  create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create function auth.role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claim.role', true), '') $$;
  grant execute on function auth.uid() to anon, authenticated; grant execute on function auth.role() to anon, authenticated;
  grant select on auth.users to authenticated;
`);
// the old schema that is live today, with one existing student
const old = fs.readFileSync(process.argv[3], 'utf8');
await db.exec(old);
const now = Date.now();
const data = (n) => ({
  progress: { v: 1, lessons: { asthma: { maxPos: 40, total: 41 }, copd: { maxPos: 10, total: 41 } } },
  ticks: { asthma: now },
  ev: { asthma: Array.from({ length: n }, (_, i) => [now - i * 3600e3, i % 2 ? 'diagnosis' : 'management', i % 3 ? 'bank' : 'sba', i % 4 ? 1 : 0]),
        copd: [[now - 10 * 86400e3, 'science', 'blurt', 0.5]] },
  arena: { 'asthma|p1': { n: 3, right: 2 }, 'copd|p2': { n: 1, right: 0 } },
  corr: [{ key: 'a', fixed: false, src: 'Quesmed' }, { key: 'b', fixed: true, src: 'bank' }, { key: 'c', fixed: false }],
  srs: { 'b|asthma|x': { due: now - 1000 }, 'b|asthma|y': { due: now + 86400e3 } },
  nread: { asthma: {} }, notes: { asthma: { diagnosis: { 0: {} } } }, updatedAt: now,
});
const [legacy] = await q(`insert into auth.users (email, last_sign_in_at) values ('oldie@year3notes.app', now()) returning id`);
await q(`insert into public.year3_progress (user_id, username, data) values ($1, 'oldie', $2)`, [legacy.id, data(12)]);

// ---- run the new schema twice (it must be safe to re-run) ----
await db.exec(schema);
ok(true, 'schema ran');
await db.exec(schema);
ok(true, 'schema ran a second time');

const prof = await q(`select * from public.profiles`);
ok(prof.length === 1 && prof[0].username === 'oldie', 'existing student got a profile');
const st0 = await q(`select * from public.student_stats where user_id = $1`, [legacy.id]);
ok(st0.length === 1 && st0[0].answers_total === 13, 'existing student got stats from their save: ' + JSON.stringify(st0[0] && {a: st0[0].answers_total, acc: st0[0].accuracy}));
const prog0 = await q(`select * from public.year3_progress where user_id = $1`, [legacy.id]);
ok(prog0[0].data.ev.asthma.length === 12, 'existing progress kept');

// ---- sign ups through the auth table ----
const [a] = await q(`insert into auth.users (email, raw_user_meta_data) values ('victor@year3notes.app', '{"username":"victor"}') returning id`);
const [b] = await q(`insert into auth.users (email) values ('sam.k@year3notes.app') returning id`);
ok((await q(`select username from public.profiles where id = $1`, [a.id]))[0]?.username === 'victor', 'sign up makes a profile');
ok((await q(`select count(*)::int n from public.app_events where kind = 'sign_up'`))[0].n === 2, 'sign ups are logged');
await q(`update auth.users set last_sign_in_at = now() where id = $1`, [a.id]);
const pa = (await q(`select sign_ins, last_sign_in_at from public.profiles where id = $1`, [a.id]))[0];
ok(pa.sign_ins === 1 && pa.last_sign_in_at, 'log in is counted');

// ---- act as a signed-in student, like the app does ----
const as = async (uid, fn) => {
  await db.exec(`set role authenticated`);
  await q(`select set_config('request.jwt.claim.sub', $1, false), set_config('request.jwt.claim.role', 'authenticated', false)`, [uid]);
  try { return await fn(); } finally { await db.exec(`reset role`); await q(`select set_config('request.jwt.claim.sub', '', false)`); }
};
const upsert = (uid, d) => q(`insert into public.year3_progress (user_id, username, data) values ($1, 'x', $2)
  on conflict (user_id) do update set username = excluded.username, data = excluded.data`, [uid, d]);

await as(a.id, () => upsert(a.id, data(30)));
await as(a.id, () => upsert(a.id, data(40)));
const sa = (await q(`select * from public.student_stats where user_id = $1`, [a.id]))[0];
ok(sa.answers_total === 41 && sa.lessons_started === 2 && sa.lessons_finished === 1, 'stats: answers 41, lessons 2 started 1 finished');
ok(sa.corrections_open === 2 && sa.corrections_external === 1 && sa.srs_cards === 2 && sa.srs_due === 1, 'stats: corrections and SRS');
ok(sa.arena_answers === 4 && sa.arena_right === 2 && sa.conditions_ticked === 1 && sa.notes_read === 1 && sa.notes_edited === 1, 'stats: arena, ticks, notes');
ok(sa.domain_accuracy && sa.domain_accuracy.diagnosis != null, 'stats: domain accuracy ' + JSON.stringify(sa.domain_accuracy));
const pr = (await q(`select saves, created_at < updated_at as later from public.year3_progress where user_id = $1`, [a.id]))[0];
ok(pr.saves === 2, 'save counter: ' + pr.saves);
const da = (await q(`select * from public.daily_activity where user_id = $1`, [a.id]))[0];
ok(da && da.saves === 2 && da.answers > 0, 'daily activity: saves 2, answers today ' + (da && da.answers));
ok((await q(`select last_seen_at from public.profiles where id = $1`, [a.id]))[0].last_seen_at, 'last seen updated by a save');

// a broken save still saves (stats are skipped, not the save)
await as(b.id, () => upsert(b.id, { ev: { x: 'nonsense' }, corr: { not: 'array' }, srs: [1, 2], progress: 5 }));
ok((await q(`select count(*)::int n from public.year3_progress where user_id = $1`, [b.id]))[0].n === 1, 'odd-shaped save still saved');

// ---- privacy ----
ok((await as(a.id, () => q(`select * from public.year3_progress`))).length === 1, 'a student sees only their own save');
ok((await as(a.id, () => q(`select * from public.profiles`))).length === 1, 'a student sees only their own profile');
ok((await as(a.id, () => q(`select * from public.app_events`))).length === 0, 'a student cannot read events');
await expectErr(() => as(a.id, () => q(`update public.profiles set role = 'admin' where id = $1`, [a.id])), 'a student cannot make themselves admin');
await expectErr(() => as(a.id, () => q(`insert into public.year3_progress (user_id, data) values ($1, '{}')`, [legacy.id])), "a student cannot write someone else's save");
await expectErr(() => as(a.id, () => q(`select public.admin_list_users()`)), 'a student cannot use admin functions');
await expectErr(() => as(a.id, () => q(`insert into public.student_stats (user_id) values ($1)`, [a.id])), 'a student cannot write stats');
await expectErr(() => as(a.id, () => q(`select * from admin.users`)), 'a student cannot read the admin schema');
await as(a.id, () => q(`update public.profiles set display_name = 'Victor O', cohort = '2026' where id = $1`, [a.id]));
ok((await q(`select display_name from public.profiles where id = $1`, [a.id]))[0].display_name === 'Victor O', 'a student can set their display name');
await db.exec('set role anon');
await expectErr(() => db.query(`select * from public.year3_progress`), 'logged-out visitors cannot read saves');
await expectErr(() => db.query(`select public.admin_overview()`), 'logged-out visitors cannot call admin functions');
await expectErr(() => db.query(`select public.log_event('open')`), 'logged-out visitors cannot log events');
await db.exec('reset role');

// events from the app
await as(a.id, () => q(`select public.log_event('open', '{"device":"iPhone Safari"}')`));
await as(a.id, () => q(`select public.log_event('sign_up', '{}')`)); // ignored: only the database logs sign ups
ok((await q(`select count(*)::int n from public.app_events where user_id = $1 and kind = 'open'`, [a.id]))[0].n === 1, 'app open logged');
ok((await q(`select count(*)::int n from public.app_events where user_id = $1 and kind = 'sign_up'`, [a.id]))[0].n === 1, 'fake sign_up event ignored');
ok((await q(`select last_device from public.profiles where id = $1`, [a.id]))[0].last_device === 'iPhone Safari', 'device recorded');

// ---- admin ----
await q(`update public.profiles set role = 'admin' where username = 'victor'`);
const ov = (await as(a.id, () => q(`select public.admin_overview() r`)))[0].r;
ok(ov.totals.students === 3 && ov.daily.length === 30, 'admin overview: ' + JSON.stringify({ students: ov.totals.students, active7: ov.totals.active_7d, answers: ov.totals.answers_total, acc: ov.totals.avg_accuracy, domains: ov.domains }));
const users = (await as(a.id, () => q(`select public.admin_list_users() r`)))[0].r;
ok(users.length === 3 && users.some(u => u.username === 'sam.k'), 'admin sees every student: ' + users.map(u => u.username).join(', '));
const det = (await as(a.id, () => q(`select public.admin_user_detail($1) r`, [legacy.id])))[0].r;
ok(det.user.username === 'oldie', 'admin student detail');
await as(a.id, () => q(`select public.admin_set_status($1, 'suspended')`, [b.id]));
await expectErr(() => as(b.id, () => upsert(b.id, data(1))), 'a suspended student cannot save');
await as(a.id, () => q(`select public.admin_set_status($1, 'active')`, [b.id]));
await as(b.id, () => upsert(b.id, data(1)));
ok(true, 'reactivated student can save again');
await as(a.id, () => q(`select public.admin_reset_password($1, 'newpass1')`, [b.id]));
ok((await q(`select encrypted_password = extensions.crypt('newpass1', encrypted_password) ok from auth.users where id = $1`, [b.id]))[0].ok, 'admin password reset works');
await expectErr(() => as(a.id, () => q(`select public.admin_set_role($1, 'student')`, [a.id])), 'admin cannot demote themselves');
await as(a.id, () => q(`select public.admin_set_note($1, 'Year 3 Imperial')`, [b.id]));
await as(a.id, () => q(`select public.admin_delete_user($1)`, [legacy.id]));
ok((await q(`select count(*)::int n from public.year3_progress where user_id = $1`, [legacy.id]))[0].n === 0, 'deleting a student removes their data');
ok((await q(`select count(*)::int n from public.admin_audit`))[0].n === 5, 'admin actions are in the audit log');

// ---- views for the dashboard ----
console.log('admin.overview', JSON.stringify((await q(`select * from admin.overview`))[0]));
console.log('admin.users', JSON.stringify((await q(`select username, joined_at, lessons_finished, answers_total, accuracy, streak_days, active_days_7, save_kb from admin.users`))));
console.log('admin.daily (today)', JSON.stringify((await q(`select * from admin.daily limit 1`))[0]));
console.log('admin.events', (await q(`select kind, username from admin.events`)).map(r => r.kind + ':' + r.username).join(' '));
console.log('admin.audit', (await q(`select action, target_name from admin.audit`)).map(r => r.action + ':' + r.target_name).join(' '));

// ---- scale: 250 students with large saves ----
const big = data(400);
for (const c of Array.from({ length: 200 }, (_, i) => 'cond' + i)) big.ev[c] = Array.from({ length: 60 }, (_, i) => [now - i * 6e5, 'diagnosis', 'bank', i % 3 ? 1 : 0]);
for (let i = 0; i < 250; i++) {
  const [u] = await q(`insert into auth.users (email) values ($1) returning id`, [`student${i}@year3notes.app`]);
  if (i < 25) await as(u.id, () => upsert(u.id, big));
}
let t = Date.now();
const [uu] = await q(`select id from auth.users where email = 'student0@year3notes.app'`);
for (let i = 0; i < 20; i++) await as(uu.id, () => upsert(uu.id, big));
console.log(`one large save (${JSON.stringify(big).length >> 10} KB, ${12000 + 400} answers) takes ~${Math.round((Date.now() - t) / 20)} ms including stats`);
t = Date.now();
const all = (await as(a.id, () => q(`select public.admin_list_users() r`)))[0].r;
console.log(`admin list of ${all.length} students: ${Date.now() - t} ms; overview: ` + (await (async () => { const t2 = Date.now(); await as(a.id, () => q(`select public.admin_overview()`)); return Date.now() - t2; })()) + ' ms');
ok(all.length === 252, 'admin lists all 252 students');

// every read-only query in admin_queries.sql runs
if (process.argv[4]) {
  const stmts = fs.readFileSync(process.argv[4], 'utf8').split('\n').filter(l => !l.trim().startsWith('--')).join('\n')
    .split(';').map(x => x.trim()).filter(Boolean);
  for (const st of stmts) { try { await db.query(st); ok(true, 'query: ' + st.split('\n')[0].slice(0, 60)); } catch (e) { ok(false, 'query failed: ' + st.slice(0, 60) + ' -> ' + e.message); } }
}
console.log(fails ? `\n${fails} FAILED` : '\nALL PASSED');
process.exit(fails ? 1 : 0);
