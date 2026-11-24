-- 퐁당 프리다이빙 · Supabase 설정 (SQL Editor에 통째로 붙여넣고 Run 한 번)
-- 하는 일: 진행 기록 저장 · 닉네임 영구 중복 방지 · 운영자 확인 · 다른 기기에서 계정 코드로 이어 하기
-- 표는 외부에서 직접 못 읽게 잠그고, 아래 함수로만 접근해요. (남의 기록/계정 코드가 노출되지 않아요)

create table if not exists public.pd_players (
  token      text primary key check (token ~ '^[A-Z2-9]{16}$'),
  save       text,
  save_t     timestamptz,
  name       text,
  name_lower text,
  created_at timestamptz default now()
);
create unique index if not exists pd_players_name_uq on public.pd_players (name_lower) where name_lower is not null;

create table if not exists public.pd_config (key text primary key, value text not null);

alter table public.pd_players enable row level security;
alter table public.pd_config  enable row level security;
-- 정책(policy)을 만들지 않으므로 anon 키로는 표를 직접 읽거나 쓸 수 없어요.

create or replace function public.pd_load(p_token text) returns jsonb
language sql security definer set search_path = public as $$
  select case when p.save is null then null
              else jsonb_build_object('j', p.save, 't', (extract(epoch from p.save_t) * 1000)::bigint) end
  from public.pd_players p where p.token = p_token
$$;

create or replace function public.pd_save(p_token text, p_save text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_token !~ '^[A-Z2-9]{16}$' or p_save is null or length(p_save) > 60000 then raise exception 'bad request'; end if;
  perform p_save::jsonb;  -- JSON 이 아니면 오류
  insert into public.pd_players (token, save, save_t) values (p_token, p_save, now())
  on conflict (token) do update set save = excluded.save, save_t = now();
end $$;

create or replace function public.pd_claim_name(p_token text, p_name text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n text := left(btrim(coalesce(p_name, '')), 10); l text := lower(n);
begin
  if p_token !~ '^[A-Z2-9]{16}$' then return false; end if;
  if n = '' or l = '다이버' then return true; end if;
  if exists (select 1 from public.pd_players where name_lower = l and token <> p_token) then return false; end if;
  insert into public.pd_players (token, name, name_lower) values (p_token, n, l)
  on conflict (token) do update set name = excluded.name, name_lower = excluded.name_lower;
  return true;
exception when unique_violation then return false;
end $$;

create or replace function public.pd_taken_names(p_token text) returns text[]
language sql security definer set search_path = public as $$
  select coalesce(array_agg(name_lower), '{}'::text[]) from public.pd_players
  where name_lower is not null and token <> p_token
$$;

create or replace function public.pd_has(p_token text) returns boolean
language sql security definer set search_path = public as $$
  select exists (select 1 from public.pd_players where token = p_token and save is not null)
$$;

create or replace function public.pd_is_owner(p_token text, p_admin text) returns boolean
language sql security definer set search_path = public as $$
  select length(coalesce(p_admin, '')) >= 12
     and exists (select 1 from public.pd_config where key = 'admin' and value = p_admin)
$$;

revoke all on function public.pd_load(text), public.pd_save(text, text), public.pd_claim_name(text, text),
  public.pd_taken_names(text), public.pd_has(text), public.pd_is_owner(text, text) from public;
grant execute on function public.pd_load(text), public.pd_save(text, text), public.pd_claim_name(text, text),
  public.pd_taken_names(text), public.pd_has(text), public.pd_is_owner(text, text) to anon, authenticated;

-- ★ 아래 '여기에바꾸세요' 를 길고 남이 모르는 운영자 키(12자 이상)로 바꾼 뒤 Run 하세요.
--   안 바꾸면 운영자 기능은 꺼진 채로 있어요.
insert into public.pd_config (key, value) values ('admin', '여기에바꾸세요')
on conflict (key) do update set value = excluded.value;
