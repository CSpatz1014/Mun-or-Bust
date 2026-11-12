-- Mun or Bust workspace upgrade. Apply AFTER the existing base and chat schemas.
-- Additive and rerunnable; existing accounts, tasks, ideas and chat are preserved.
begin;
create table if not exists public.mission_records (
 id uuid primary key default gen_random_uuid(),
 kind text not null check(kind in ('requirements','research','decisions','budgets','meetings','reviews','submissions','designs','risks','polls','assumptions')),
 title text not null check(length(btrim(title)) between 1 and 200),
 status text not null default 'Draft',owner uuid references public.profiles(id) on delete set null,
 due_at timestamptz,data jsonb not null default '{}' check(jsonb_typeof(data)='object'),
 author uuid references public.profiles(id) on delete set null,version integer not null default 1,
 archived boolean not null default false,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.mission_history (
 record_id uuid not null references public.mission_records(id) on delete cascade,
 version integer not null,snapshot jsonb not null,editor uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),primary key(record_id,version)
);
create table if not exists public.availability_votes (
 record_id uuid not null references public.mission_records(id) on delete cascade,slot_id text not null,
 user_id uuid not null references public.profiles(id) on delete cascade,
 answer text not null check(answer in ('yes','maybe','no')),updated_at timestamptz not null default now(),primary key(record_id,slot_id,user_id)
);
create table if not exists public.mission_notifications (
 id uuid primary key default gen_random_uuid(),recipient uuid not null references public.profiles(id) on delete cascade,
 title text not null,route text not null,entity_id text,read_at timestamptz,created_at timestamptz not null default now()
);
create table if not exists public.chat_reads (
 user_id uuid not null references public.profiles(id) on delete cascade,channel_id uuid not null references public.chat_channels(id) on delete cascade,
 last_message_id bigint not null default 0,primary key(user_id,channel_id)
);
create table if not exists public.chat_pins (
 message_id bigint primary key references public.chat_messages(id) on delete cascade,
 pinned_by uuid references public.profiles(id) on delete set null,created_at timestamptz not null default now()
);
create table if not exists public.chat_assets (
 message_id bigint primary key references public.chat_messages(id) on delete cascade,
 path text not null,name text not null check(length(name)<=240),mime text not null
);
alter table public.profiles add column if not exists avatar_path text;
grant update(avatar_path) on public.profiles to authenticated;
create index if not exists mission_kind_updated on public.mission_records(kind,updated_at desc);
create index if not exists mission_notifications_recipient on public.mission_notifications(recipient,created_at desc);
create or replace function public.is_reviewer() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.profiles where id=auth.uid() and active and role in ('mentor','admin'))$$;
-- All writes to collaborative records go through a version-checked function.
create or replace function public.save_mission_record(record_id uuid,expected_version integer,record_kind text,record_title text,record_status text,record_owner uuid,record_due timestamptz,record_data jsonb,archive_record boolean default false)
returns public.mission_records language plpgsql security definer set search_path='' as $$
declare oldrow public.mission_records; result public.mission_records; reviewer record;
begin
 if not public.is_member() then raise exception 'Active membership required';end if;
 if record_data is null or jsonb_typeof(record_data)<>'object' or octet_length(record_data::text)>100000 then raise exception 'Invalid record data';end if;
 if record_owner is not null and not exists(select 1 from public.profiles where id=record_owner and active) then raise exception 'Owner must be an active member';end if;
 if record_id is not null then
  select * into oldrow from public.mission_records where id=record_id for update;
  if not found then raise exception 'Record not found';end if;
  if oldrow.version is distinct from expected_version then raise exception 'Someone changed this record. Refresh and reopen it before saving.';end if;
  if oldrow.kind<>record_kind then raise exception 'Cannot change record type';end if;
 end if;
 if record_kind='reviews' and record_status in ('Approved','Changes requested') and not public.is_reviewer() then
  raise exception 'Mentor or admin review required; set the record to Draft for a new review cycle';
 end if;
 if record_id is null then
  insert into public.mission_records(kind,title,status,owner,due_at,data,author) values(record_kind,btrim(record_title),record_status,record_owner,record_due,record_data,auth.uid()) returning * into result;
 else
  update public.mission_records set title=btrim(record_title),status=record_status,owner=record_owner,due_at=record_due,data=record_data,archived=archive_record,version=version+1,updated_at=now() where id=record_id returning * into result;
 end if;
 insert into public.mission_history(record_id,version,snapshot,editor) values(result.id,result.version,to_jsonb(result),auth.uid());
 if not result.archived and result.owner is not null and result.owner<>auth.uid() and (oldrow.id is null or oldrow.owner is distinct from result.owner) then
  insert into public.mission_notifications(recipient,title,route,entity_id) values(result.owner,'Assigned: '||result.title,'Project hub',result.id::text);
 end if;
 if record_kind='reviews' and result.status='Ready for review' and oldrow.status is distinct from result.status then
  for reviewer in select id from public.profiles where active and role in ('mentor','admin') and id<>auth.uid() loop
   insert into public.mission_notifications(recipient,title,route,entity_id) values(reviewer.id,'Review requested: '||result.title,'Project hub',result.id::text);
  end loop;
 elsif record_kind='reviews' and result.status in ('Approved','Changes requested') and oldrow.status is distinct from result.status and result.author<>auth.uid() then
  insert into public.mission_notifications(recipient,title,route,entity_id) values(result.author,result.status||': '||result.title,'Project hub',result.id::text);
 end if;
 return result;
end$$;
-- Convert selected meeting action lines atomically and remember completed lines.
create or replace function public.create_meeting_tasks(meeting_id uuid,expected_version integer,action_lines text[]) returns void language plpgsql security definer set search_path='' as $$
declare r public.mission_records; line text; done jsonb; nextdata jsonb;
begin
 if not public.is_member() then raise exception 'Active membership required';end if;
 select * into r from public.mission_records where id=meeting_id and kind='meetings' and not archived for update;
 if not found then raise exception 'Meeting unavailable';end if;
 if r.version is distinct from expected_version then raise exception 'Meeting changed. Refresh and reopen it.';end if;
 done=coalesce(r.data->'createdActions','[]'::jsonb);
 foreach line in array action_lines loop
  if length(line) not between 1 and 160 or not exists(select 1 from regexp_split_to_table(coalesce(r.data->>'actions',''),E'\\n') x where btrim(x)=line) then raise exception 'Action must match a meeting line and contain at most 160 characters';end if;
  if not done ? line then
   insert into public.tasks(title,description,kind,status,priority,assignee,author) values(line,'From meeting: '||r.title,'task','To do','Normal',r.owner,auth.uid());
   done=done||jsonb_build_array(line);
  end if;
 end loop;
 nextdata=jsonb_set(r.data,'{createdActions}',done);
 perform public.save_mission_record(r.id,r.version,r.kind,r.title,r.status,r.owner,r.due_at,nextdata,r.archived);
end$$;
revoke all on function public.create_meeting_tasks(uuid,integer,text[]) from public;
grant execute on function public.create_meeting_tasks(uuid,integer,text[]) to authenticated;
create or replace function public.vote_availability(poll_id uuid,slot text,response text) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_member() then raise exception 'Active membership required';end if;
 if not exists(select 1 from public.mission_records r, jsonb_array_elements(coalesce(r.data->'slots','[]')) s where r.id=poll_id and r.kind='polls' and not r.archived and r.status<>'Closed' and s->>'id'=slot) then raise exception 'This poll slot is closed or unavailable';end if;
 insert into public.availability_votes(record_id,slot_id,user_id,answer) values(poll_id,slot,auth.uid(),response) on conflict on constraint availability_votes_pkey do update set answer=excluded.answer,updated_at=now();
end$$;
create or replace function public.mark_chat_read(channel uuid,message_id bigint) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_member() then raise exception 'Active membership required';end if;
 if not exists(select 1 from public.chat_messages where id=message_id and channel_id=channel) then return;end if;
 insert into public.chat_reads values(auth.uid(),channel,message_id) on conflict on constraint chat_reads_pkey do update set last_message_id=greatest(public.chat_reads.last_message_id,excluded.last_message_id);
end$$;
create or replace function public.chat_unread_counts() returns table(channel_id uuid,unread bigint) language sql stable security definer set search_path='' as $$
 select c.id,count(m.id) from public.chat_channels c left join public.chat_reads r on r.channel_id=c.id and r.user_id=auth.uid() left join public.chat_messages m on m.channel_id=c.id and m.id>coalesce(r.last_message_id,0) and m.author is distinct from auth.uid() and not m.deleted where public.is_member() group by c.id
$$;
create or replace function public.pin_chat_message(message_id bigint,pin boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_reviewer() then raise exception 'Only mentors and admins can manage pins';end if;
 if not exists(select 1 from public.chat_messages where id=message_id and not deleted) then raise exception 'Message unavailable';end if;
 if pin then insert into public.chat_pins(message_id,pinned_by) values(message_id,auth.uid()) on conflict do nothing;else delete from public.chat_pins p where p.message_id=pin_chat_message.message_id;end if;
end$$;
create or replace function public.search_chat(channel uuid,query_text text default '',author_id uuid default null,pinned_only boolean default false,before_id bigint default null)
returns setof public.chat_messages language sql stable security invoker set search_path='' as $$
 select m.* from public.chat_messages m where m.channel_id=channel and (before_id is null or m.id<=before_id) and (author_id is null or m.author=author_id) and (coalesce(query_text,'')='' or (not m.deleted and strpos(lower(m.body),lower(query_text))>0)) and (not pinned_only or (not m.deleted and exists(select 1 from public.chat_pins p where p.message_id=m.id))) order by m.id desc limit 61
$$;
create or replace function public.send_chat_v2(channel uuid,message_body text,nonce uuid,reply_id bigint default null,asset_path text default null,asset_name text default null,asset_mime text default null)
returns bigint language plpgsql security definer set search_path='' as $$declare message_id bigint; target record;begin
 if not public.is_member() then raise exception 'Active membership required';end if;
 select id into message_id from public.chat_messages where client_nonce=nonce and author=auth.uid();if found then return message_id;end if;
 if asset_path is not null and (split_part(asset_path,'/',1)<>auth.uid()::text or asset_name is null or asset_mime is null or not exists(select 1 from storage.objects where bucket_id='mission-files' and name=asset_path)) then raise exception 'Invalid attachment';end if;
 insert into public.chat_messages(channel_id,body,author,client_nonce,reply_to) values(channel,message_body,auth.uid(),nonce,reply_id) returning id into message_id;
 if asset_path is not null then insert into public.chat_assets(message_id,path,name,mime) values(message_id,asset_path,asset_name,asset_mime);end if;
 return message_id;
end$$;
create or replace function public.notify_chat_mentions() returns trigger language plpgsql security definer set search_path='' as $$declare target record;begin
 for target in select id,name from public.profiles where active and id<>new.author and strpos(new.body,'@{'||id::text||'}')>0 loop
  insert into public.mission_notifications(recipient,title,route,entity_id) values(target.id,'Mentioned in chat','Chat',new.channel_id::text);
 end loop;return new;
end$$;
drop trigger if exists mission_chat_mentions on public.chat_messages;
create trigger mission_chat_mentions after insert on public.chat_messages for each row execute function public.notify_chat_mentions();
create or replace function public.notify_task_assignment() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.assignee is not null and new.assignee is distinct from auth.uid() and (tg_op='INSERT' or new.assignee is distinct from old.assignee) then insert into public.mission_notifications(recipient,title,route,entity_id) values(new.assignee,'Task assigned: '||new.title,'Deadlines & tasks',new.id::text);end if;return new;
end$$;
drop trigger if exists mission_task_assignment on public.tasks;
create trigger mission_task_assignment after insert or update on public.tasks for each row execute function public.notify_task_assignment();
-- Explicit privileges and RLS: no anonymous access; notifications/read cursors are private.
do $$declare t text;begin
 foreach t in array array['mission_records','mission_history','availability_votes','mission_notifications','chat_reads','chat_pins','chat_assets'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('drop policy if exists member_read on public.%I',t);
  if t='mission_notifications' then execute 'create policy member_read on public.mission_notifications for select to authenticated using(public.is_member() and recipient=auth.uid())';
  elsif t='chat_reads' then execute 'create policy member_read on public.chat_reads for select to authenticated using(public.is_member() and user_id=auth.uid())';
  elsif t='chat_assets' then execute 'create policy member_read on public.chat_assets for select to authenticated using(public.is_member() and exists(select 1 from public.chat_messages m where m.id=message_id and not m.deleted))';
  else execute format('create policy member_read on public.%I for select to authenticated using(public.is_member())',t);end if;
 end loop;
end$$;
grant update(read_at) on public.mission_notifications to authenticated;
drop policy if exists notifications_read_update on public.mission_notifications;
create policy notifications_read_update on public.mission_notifications for update to authenticated using(public.is_member() and recipient=auth.uid()) with check(public.is_member() and recipient=auth.uid());
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('mission-files','mission-files',false,10485760,array['image/png','image/jpeg','image/webp','application/pdf','text/plain','text/csv','application/zip','application/octet-stream']) on conflict(id) do nothing;
drop policy if exists mission_files_read on storage.objects;
create policy mission_files_read on storage.objects for select to authenticated using(bucket_id='mission-files' and public.is_member());
drop policy if exists mission_files_insert on storage.objects;
create policy mission_files_insert on storage.objects for insert to authenticated with check(bucket_id='mission-files' and public.is_member() and (storage.foldername(name))[1]=auth.uid()::text);
-- Old design revisions retain their files; deletion is an owner/admin maintenance operation.
drop policy if exists mission_files_delete on storage.objects;
create policy mission_files_delete on storage.objects for delete to authenticated using(bucket_id='mission-files' and public.is_member() and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));
revoke all on function public.is_reviewer(),public.save_mission_record(uuid,integer,text,text,text,uuid,timestamptz,jsonb,boolean),public.vote_availability(uuid,text,text),public.mark_chat_read(uuid,bigint),public.chat_unread_counts(),public.pin_chat_message(bigint,boolean),public.search_chat(uuid,text,uuid,boolean,bigint),public.send_chat_v2(uuid,text,uuid,bigint,text,text,text),public.notify_chat_mentions(),public.notify_task_assignment() from public;
grant execute on function public.is_reviewer(),public.save_mission_record(uuid,integer,text,text,text,uuid,timestamptz,jsonb,boolean),public.vote_availability(uuid,text,text),public.mark_chat_read(uuid,bigint),public.chat_unread_counts(),public.pin_chat_message(bigint,boolean),public.search_chat(uuid,text,uuid,boolean,bigint),public.send_chat_v2(uuid,text,uuid,bigint,text,text,text) to authenticated;
commit;
