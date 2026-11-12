-- Apply after mission-upgrade.sql. Additive, rerunnable, announcements disabled by default.
begin;
create table if not exists public.discord_settings (
 id boolean primary key default true check(id), enabled boolean not null default false,
 server_url text not null default '', events text[] not null default array['deadlines','reviews','meetings','submissions'],
 check(server_url='' or server_url ~ '^https://discord[.]com/channels/[0-9]+(/[0-9]+)?$'),
 check(events <@ array['tasks','deadlines','reviews','meetings','decisions','submissions','designs'])
);
insert into public.discord_settings(id) values(true) on conflict do nothing;
create table if not exists public.discord_links (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 discord_id text not null unique check(discord_id ~ '^[0-9]{15,22}$'),
 synced_role text, synced_at timestamptz, sync_error text, locked_until timestamptz
);
create table if not exists public.discord_oauth_states (
 state_hash text primary key,user_id uuid not null references public.profiles(id) on delete cascade,
 expires_at timestamptz not null default now()+interval '10 minutes'
);
create table if not exists public.discord_outbox (
 id uuid primary key default gen_random_uuid(),category text not null,payload jsonb not null,
 status text not null default 'pending' check(status in ('pending','sending','sent','failed','cancelled')),
 created_at timestamptz not null default now(),started_at timestamptz,sent_at timestamptz,
 error_code text,retry_after timestamptz,discord_message_id text,retry_of uuid unique references public.discord_outbox(id),
 check(octet_length(payload::text)<8000)
);
create index if not exists discord_recent on public.discord_outbox(created_at desc);
alter table public.discord_settings enable row level security;
alter table public.discord_links enable row level security;
alter table public.discord_oauth_states enable row level security;
alter table public.discord_outbox enable row level security;
revoke all on public.discord_settings,public.discord_links,public.discord_oauth_states,public.discord_outbox from anon,authenticated;
grant select on public.discord_settings,public.discord_links,public.discord_outbox to authenticated;
grant select on public.profiles,public.discord_settings to service_role;
grant select,insert,update,delete on public.discord_oauth_states to service_role;
grant select,insert,update on public.discord_links,public.discord_outbox to service_role;
drop policy if exists discord_settings_read on public.discord_settings;
create policy discord_settings_read on public.discord_settings for select to authenticated using(public.is_member());
drop policy if exists discord_links_read on public.discord_links;
create policy discord_links_read on public.discord_links for select to authenticated using(public.is_member() and (user_id=auth.uid() or public.is_admin()));
drop policy if exists discord_outbox_read on public.discord_outbox;
create policy discord_outbox_read on public.discord_outbox for select to authenticated using(public.is_admin());
create or replace function public.configure_discord(active boolean,server_link text,event_types text[]) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_admin() then raise exception 'Admin access required';end if;
 update public.discord_settings set enabled=active,server_url=btrim(server_link),events=event_types where id;
 if not active then update public.discord_outbox set status='cancelled',error_code='disabled' where category<>'access' and status in ('pending','failed');end if;
end$$;
create or replace function public.queue_discord_event(category_name text,event_payload jsonb) returns void language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.discord_settings where enabled and category_name=any(events)) then insert into public.discord_outbox(category,payload) values(category_name,event_payload);end if;
end$$;
create or replace function public.discord_task_event() returns trigger language plpgsql security definer set search_path='' as $$declare category_name text;label text;begin
 if new.kind='deadline' then
  if tg_op='INSERT' then label='Deadline added';elsif new.due_at is distinct from old.due_at or new.due_date is distinct from old.due_date then label='Deadline date changed';else return new;end if;category_name='deadlines';
 else
  if tg_op='INSERT' then label='Task created';elsif new.status='Done' and old.status is distinct from new.status then label='Task completed';else return new;end if;category_name='tasks';
 end if;
 perform public.queue_discord_event(category_name,jsonb_build_object('label',label,'title',new.title,'status',new.status,'due_at',new.due_at,'due_date',new.due_date,'route','tasks'));return new;
end$$;
drop trigger if exists discord_tasks on public.tasks;
create trigger discord_tasks after insert or update on public.tasks for each row execute function public.discord_task_event();
create or replace function public.discord_record_event() returns trigger language plpgsql security definer set search_path='' as $$declare label text;begin
 if new.archived then return new;end if;
 if new.kind='reviews' and new.status in ('Ready for review','Approved','Changes requested') then label='Review: '||new.status;
 elsif new.kind='meetings' and new.status='Planned' and new.due_at is not null then label='Meeting planned';
 elsif new.kind='decisions' and new.status='Accepted' then label='Decision accepted';
 elsif new.kind='submissions' and new.status='Done' then label='Submission item completed';
 elsif new.kind='designs' and new.status='Released' then label='Design released';else return new;end if;
 if tg_op='UPDATE' and old.status=new.status and not old.archived and (new.kind<>'meetings' or old.due_at is not distinct from new.due_at) then return new;end if;
 perform public.queue_discord_event(new.kind,jsonb_build_object('label',label,'title',new.title,'status',new.status,'due_at',new.due_at,'route','project/'||new.kind,'revision',new.version));return new;
end$$;
drop trigger if exists discord_records on public.mission_records;
create trigger discord_records after insert or update on public.mission_records for each row execute function public.discord_record_event();
create or replace function public.discord_access_event() returns trigger language plpgsql security definer set search_path='' as $$begin
 if (new.active is distinct from old.active or new.role is distinct from old.role) and exists(select 1 from public.discord_links where user_id=new.id) then
 insert into public.discord_outbox(category,payload) values('access',jsonb_build_object('user_id',new.id,'label','Team access update'));end if;return new;
end$$;
drop trigger if exists discord_access on public.profiles;
create trigger discord_access after update on public.profiles for each row execute function public.discord_access_event();
create or replace function public.request_discord_sync(target uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_member() or (target<>auth.uid() and not public.is_admin()) then raise exception 'Access denied';end if;
 if not exists(select 1 from public.discord_links where user_id=target) then raise exception 'Connect a Discord account first';end if;
 if exists(select 1 from public.discord_outbox where category='access' and payload->>'user_id'=target::text and created_at>now()-interval '30 seconds') then raise exception 'Wait 30 seconds before requesting another sync';end if;
 insert into public.discord_outbox(category,payload) values('access',jsonb_build_object('user_id',target,'label','Role sync requested'));
end$$;
create or replace function public.test_discord_delivery() returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_admin() then raise exception 'Admin access required';end if;
 if not exists(select 1 from public.discord_settings where enabled) then raise exception 'Enable announcements first';end if;
 if exists(select 1 from public.discord_outbox where category='test' and created_at>now()-interval '30 seconds') then raise exception 'Wait 30 seconds before another test';end if;
 insert into public.discord_outbox(category,payload) values('test','{"label":"Connection test","title":"Mun or Bust mission updates are connected","route":"dashboard"}');
end$$;
create or replace function public.retry_discord_delivery(delivery_id uuid) returns void language plpgsql security definer set search_path='' as $$declare r public.discord_outbox;begin
 if not public.is_admin() then raise exception 'Admin access required';end if;
 select * into r from public.discord_outbox where id=delivery_id for update;
 if not found or not(r.status='failed' or(r.status in ('pending','sending') and coalesce(r.started_at,r.created_at)<now()-interval '5 minutes')) then raise exception 'Not ready to retry';end if;
 if r.category<>'access' and not exists(select 1 from public.discord_settings where enabled) then raise exception 'Announcements disabled';end if;
 if r.retry_after>now() then raise exception 'Wait until % before retrying',r.retry_after;end if;
 if exists(select 1 from public.discord_outbox where retry_of=r.id) then raise exception 'Already retried';end if;
 update public.discord_outbox set status='cancelled',error_code='retried' where id=r.id;
 insert into public.discord_outbox(category,payload,retry_of) values(r.category,r.payload,r.id);
end$$;
create or replace function public.claim_discord_delivery(delivery_id uuid) returns setof public.discord_outbox language sql security definer set search_path='' as $$update public.discord_outbox set status='sending',started_at=now() where id=delivery_id and status='pending' returning *$$;
create or replace function public.consume_discord_state(hash text,target uuid) returns setof public.discord_oauth_states language sql security definer set search_path='' as $$delete from public.discord_oauth_states where state_hash=hash and user_id=target and expires_at>now() returning *$$;
create or replace function public.lock_discord_sync(target uuid) returns boolean language plpgsql security definer set search_path='' as $$begin update public.discord_links set locked_until=now()+interval '3 minutes' where user_id=target and (locked_until is null or locked_until<now());return found;end$$;
revoke all on function public.configure_discord(boolean,text,text[]),public.queue_discord_event(text,jsonb),public.discord_task_event(),public.discord_record_event(),public.discord_access_event(),public.request_discord_sync(uuid),public.test_discord_delivery(),public.retry_discord_delivery(uuid),public.claim_discord_delivery(uuid),public.consume_discord_state(text,uuid),public.lock_discord_sync(uuid) from public,anon,authenticated;
grant execute on function public.configure_discord(boolean,text,text[]),public.request_discord_sync(uuid),public.test_discord_delivery(),public.retry_discord_delivery(uuid) to authenticated;
grant execute on function public.claim_discord_delivery(uuid),public.consume_discord_state(text,uuid),public.lock_discord_sync(uuid) to service_role;
commit;
