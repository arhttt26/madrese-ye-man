-- ============================================================
-- مدرسهٔ من — تغییرات دیتابیس برای: «رأی من»، PDF کارنامه (۱ مگابایت)، محدودیت ۱ مگابایت پیام‌رسان
-- این فایل را یک بار در Supabase > SQL Editor اجرا کنید. چندبار اجرا کردنش مشکلی ایجاد نمی‌کند.
-- ============================================================

-- تشخیص مدیر
create or replace function public.sp_is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'manager');
$$;

-- ---------- ۱) PDF کارنامه ----------
alter table public.report_cards add column if not exists file_path text;
alter table public.report_cards add column if not exists file_name text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('report-files', 'report-files', false, 1048576, array['application/pdf'])
on conflict (id) do update set file_size_limit = 1048576, allowed_mime_types = array['application/pdf'];

drop policy if exists "report_files_manager_all" on storage.objects;
create policy "report_files_manager_all" on storage.objects for all to authenticated
  using (bucket_id = 'report-files' and public.sp_is_manager())
  with check (bucket_id = 'report-files' and public.sp_is_manager());

drop policy if exists "report_files_student_read" on storage.objects;
create policy "report_files_student_read" on storage.objects for select to authenticated
  using (bucket_id = 'report-files' and exists (
    select 1 from public.students s
    where s.user_id = auth.uid() and s.id::text = (storage.foldername(name))[1]));

-- ---------- ۲) محدودیت ۱ مگابایت پیام‌رسان (سمت دیتابیس) ----------
update storage.buckets set file_size_limit = 1048576 where id = 'chat-files';

-- ---------- ۳) رأی من ----------
create table if not exists public.vote_polls (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  status text not null default 'draft' check (status in ('draft','open','closed')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create table if not exists public.vote_candidates (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.vote_polls(id) on delete cascade,
  name text not null,
  photo text,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.vote_scores (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.vote_polls(id) on delete cascade,
  candidate_id uuid not null references public.vote_candidates(id) on delete cascade,
  voter_id uuid not null default auth.uid(),
  score int not null check (score between 1 and 10),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (candidate_id, voter_id)
);
create index if not exists vote_scores_poll_idx on public.vote_scores(poll_id);
create index if not exists vote_candidates_poll_idx on public.vote_candidates(poll_id);

alter table public.vote_polls enable row level security;
alter table public.vote_candidates enable row level security;
alter table public.vote_scores enable row level security;

drop policy if exists vote_polls_manager on public.vote_polls;
create policy vote_polls_manager on public.vote_polls for all to authenticated
  using (public.sp_is_manager()) with check (public.sp_is_manager());
drop policy if exists vote_polls_read_open on public.vote_polls;
create policy vote_polls_read_open on public.vote_polls for select to authenticated using (status = 'open');

drop policy if exists vote_cands_manager on public.vote_candidates;
create policy vote_cands_manager on public.vote_candidates for all to authenticated
  using (public.sp_is_manager()) with check (public.sp_is_manager());
drop policy if exists vote_cands_read_open on public.vote_candidates;
create policy vote_cands_read_open on public.vote_candidates for select to authenticated
  using (exists (select 1 from public.vote_polls p where p.id = poll_id and p.status = 'open'));

drop policy if exists vote_scores_manager on public.vote_scores;
create policy vote_scores_manager on public.vote_scores for all to authenticated
  using (public.sp_is_manager()) with check (public.sp_is_manager());
drop policy if exists vote_scores_own_read on public.vote_scores;
create policy vote_scores_own_read on public.vote_scores for select to authenticated using (voter_id = auth.uid());
drop policy if exists vote_scores_student_insert on public.vote_scores;
create policy vote_scores_student_insert on public.vote_scores for insert to authenticated
  with check (
    voter_id = auth.uid()
    and exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.role = 'student')
    and exists (select 1 from public.vote_polls p where p.id = poll_id and p.status = 'open')
    and exists (select 1 from public.vote_candidates c where c.id = candidate_id and c.poll_id = vote_scores.poll_id));
drop policy if exists vote_scores_student_update on public.vote_scores;
create policy vote_scores_student_update on public.vote_scores for update to authenticated
  using (voter_id = auth.uid() and exists (select 1 from public.vote_polls p where p.id = poll_id and p.status = 'open'))
  with check (voter_id = auth.uid() and exists (select 1 from public.vote_polls p where p.id = poll_id and p.status = 'open'));

-- نتایج تجمیعی فقط برای مدیر
create or replace function public.vote_results(p_poll uuid)
returns table (candidate_id uuid, voters bigint, total bigint, average numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.sp_is_manager() then raise exception 'forbidden'; end if;
  return query
    select c.id, count(s.id), coalesce(sum(s.score),0)::bigint, coalesce(round(avg(s.score)::numeric,2),0)
    from public.vote_candidates c left join public.vote_scores s on s.candidate_id = c.id
    where c.poll_id = p_poll group by c.id;
end $$;
grant execute on function public.vote_results(uuid) to authenticated;

-- نمایش زنده (Realtime)
do $$ begin
  alter publication supabase_realtime add table public.vote_scores;
exception when duplicate_object then null; when undefined_object then null; end $$;
