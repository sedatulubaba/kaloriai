-- Free quota + VIP membership schema for CalorieAI
-- Free plan: 2 successful food additions, then 10-hour cooldown.

create table if not exists public.user_memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free' check (plan in ('free', 'vip')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.food_quota_usage (
  user_id uuid primary key references auth.users(id) on delete cascade,
  free_used_count integer not null default 0 check (free_used_count >= 0),
  cooldown_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.vip_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note text,
  created_at timestamptz not null default now()
);

create unique index if not exists vip_requests_one_pending_idx
  on public.vip_requests(user_id)
  where status = 'pending';

alter table public.user_memberships enable row level security;
alter table public.food_quota_usage enable row level security;
alter table public.vip_requests enable row level security;

drop policy if exists "memberships_select_own" on public.user_memberships;
create policy "memberships_select_own"
  on public.user_memberships
  for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "quota_select_own" on public.food_quota_usage;
create policy "quota_select_own"
  on public.food_quota_usage
  for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "vip_requests_select_own" on public.vip_requests;
create policy "vip_requests_select_own"
  on public.vip_requests
  for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "vip_requests_insert_own" on public.vip_requests;
create policy "vip_requests_insert_own"
  on public.vip_requests
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create or replace function public.get_food_add_quota_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := now();
  v_plan text := 'free';
  v_used integer := 0;
  v_cooldown timestamptz := null;
begin
  if v_user_id is null then
    return jsonb_build_object(
      'allowed', false,
      'is_vip', false,
      'remaining_free', 0,
      'cooldown_until', null,
      'reason', 'auth_required'
    );
  end if;

  insert into public.user_memberships(user_id, plan)
  values (v_user_id, 'free')
  on conflict (user_id) do nothing;

  select plan into v_plan
  from public.user_memberships
  where user_id = v_user_id;

  if v_plan = 'vip' then
    return jsonb_build_object(
      'allowed', true,
      'is_vip', true,
      'remaining_free', null,
      'cooldown_until', null,
      'reason', 'vip'
    );
  end if;

  insert into public.food_quota_usage(user_id, free_used_count, cooldown_until)
  values (v_user_id, 0, null)
  on conflict (user_id) do nothing;

  select free_used_count, cooldown_until
    into v_used, v_cooldown
  from public.food_quota_usage
  where user_id = v_user_id;

  if v_cooldown is not null and v_cooldown > v_now then
    return jsonb_build_object(
      'allowed', false,
      'is_vip', false,
      'remaining_free', greatest(0, 2 - v_used),
      'cooldown_until', v_cooldown,
      'reason', 'cooldown'
    );
  end if;

  if v_cooldown is not null and v_cooldown <= v_now then
    update public.food_quota_usage
    set free_used_count = 0,
        cooldown_until = null,
        updated_at = v_now
    where user_id = v_user_id;
    v_used := 0;
  end if;

  return jsonb_build_object(
    'allowed', true,
    'is_vip', false,
    'remaining_free', greatest(0, 2 - v_used),
    'cooldown_until', null,
    'reason', 'free'
  );
end;
$$;

create or replace function public.consume_food_add_quota()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := now();
  v_plan text := 'free';
  v_used integer := 0;
  v_cooldown timestamptz := null;
begin
  if v_user_id is null then
    return jsonb_build_object(
      'allowed', false,
      'is_vip', false,
      'remaining_free', 0,
      'cooldown_until', null,
      'reason', 'auth_required'
    );
  end if;

  insert into public.user_memberships(user_id, plan)
  values (v_user_id, 'free')
  on conflict (user_id) do nothing;

  select plan into v_plan
  from public.user_memberships
  where user_id = v_user_id;

  if v_plan = 'vip' then
    return jsonb_build_object(
      'allowed', true,
      'is_vip', true,
      'remaining_free', null,
      'cooldown_until', null,
      'reason', 'vip'
    );
  end if;

  insert into public.food_quota_usage(user_id, free_used_count, cooldown_until)
  values (v_user_id, 0, null)
  on conflict (user_id) do nothing;

  select free_used_count, cooldown_until
    into v_used, v_cooldown
  from public.food_quota_usage
  where user_id = v_user_id
  for update;

  if v_cooldown is not null and v_cooldown > v_now then
    return jsonb_build_object(
      'allowed', false,
      'is_vip', false,
      'remaining_free', 0,
      'cooldown_until', v_cooldown,
      'reason', 'cooldown'
    );
  end if;

  if v_cooldown is not null and v_cooldown <= v_now then
    v_used := 0;
    v_cooldown := null;
  end if;

  if v_used < 2 then
    v_used := v_used + 1;
    if v_used >= 2 then
      v_cooldown := v_now + interval '10 hours';
    end if;

    update public.food_quota_usage
    set free_used_count = v_used,
        cooldown_until = v_cooldown,
        updated_at = v_now
    where user_id = v_user_id;

    return jsonb_build_object(
      'allowed', true,
      'is_vip', false,
      'remaining_free', greatest(0, 2 - v_used),
      'cooldown_until', v_cooldown,
      'reason', 'free'
    );
  end if;

  update public.food_quota_usage
  set cooldown_until = coalesce(cooldown_until, v_now + interval '10 hours'),
      updated_at = v_now
  where user_id = v_user_id;

  select cooldown_until into v_cooldown
  from public.food_quota_usage
  where user_id = v_user_id;

  return jsonb_build_object(
    'allowed', false,
    'is_vip', false,
    'remaining_free', 0,
    'cooldown_until', v_cooldown,
    'reason', 'cooldown'
  );
end;
$$;

create or replace function public.request_vip_upgrade(p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_plan text := 'free';
begin
  if v_user_id is null then
    return jsonb_build_object('status', 'auth_required');
  end if;

  insert into public.user_memberships(user_id, plan)
  values (v_user_id, 'free')
  on conflict (user_id) do nothing;

  select plan into v_plan
  from public.user_memberships
  where user_id = v_user_id;

  if v_plan = 'vip' then
    return jsonb_build_object('status', 'already_vip');
  end if;

  if not exists (
    select 1
    from public.vip_requests
    where user_id = v_user_id
      and status = 'pending'
  ) then
    insert into public.vip_requests(user_id, note)
    values (v_user_id, p_note);
    return jsonb_build_object('status', 'pending_created');
  end if;

  return jsonb_build_object('status', 'already_pending');
end;
$$;

revoke all on function public.get_food_add_quota_status() from public;
revoke all on function public.consume_food_add_quota() from public;
revoke all on function public.request_vip_upgrade(text) from public;

grant execute on function public.get_food_add_quota_status() to authenticated;
grant execute on function public.consume_food_add_quota() to authenticated;
grant execute on function public.request_vip_upgrade(text) to authenticated;
