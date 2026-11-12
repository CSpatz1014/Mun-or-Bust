-- Mun or Bust chat upgrade. Run in the EXISTING project's SQL Editor.
-- Additive and rerunnable. Do not rerun the original schema.sql.
begin;
create table if not exists public.chat_channels (
 id uuid primary key default gen_random_uuid(),
 name text unique not null check(name ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
 description text not null default '' check(length(description)<=240),
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);
create table if not exists public.chat_messages (
 id bigint generated always as identity primary key,
 channel_id uuid not null references public.chat_channels(id) on delete cascade,
 author uuid references public.profiles(id) on delete set null,
 body text not null check(length(body)<=4000),
 client_nonce uuid not null unique,
 reply_to bigint references public.chat_messages(id) on delete set null,
 created_at timestamptz not null default now(),
 edited_at timestamptz,
 deleted boolean not null default false,
 check(deleted or length(btrim(body))>0)
);
create index if not exists chat_messages_channel_history on public.chat_messages(channel_id,id desc);
alter table public.chat_channels enable row level security;
alter table public.chat_messages enable row level security;
revoke all on public.chat_channels,public.chat_messages from anon,authenticated;
grant select on public.chat_channels,public.chat_messages to authenticated;
grant insert(name,description,created_by) on public.chat_channels to authenticated;
grant insert(channel_id,author,body,client_nonce,reply_to) on public.chat_messages to authenticated;
grant usage on sequence public.chat_messages_id_seq to authenticated;
drop policy if exists chat_channels_read on public.chat_channels;
create policy chat_channels_read on public.chat_channels for select to authenticated using(public.is_member());
drop policy if exists chat_channels_create on public.chat_channels;
create policy chat_channels_create on public.chat_channels for insert to authenticated with check(public.is_admin() and created_by=auth.uid());
drop policy if exists chat_messages_read on public.chat_messages;
create policy chat_messages_read on public.chat_messages for select to authenticated using(public.is_member());
drop policy if exists chat_messages_send on public.chat_messages;
create policy chat_messages_send on public.chat_messages for insert to authenticated with check(public.is_member() and author=auth.uid());
create or replace function public.check_chat_reply() returns trigger language plpgsql set search_path='' as $$begin
 if new.reply_to is not null and not exists(select 1 from public.chat_messages where id=new.reply_to and channel_id=new.channel_id and not deleted) then raise exception 'Reply must reference an available message in the same channel';end if;
 return new;
end$$;
drop trigger if exists chat_reply_guard on public.chat_messages;
create trigger chat_reply_guard before insert on public.chat_messages for each row execute function public.check_chat_reply();
create or replace function public.edit_chat_message(message_id bigint,new_body text) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_member() then raise exception 'Active membership required';end if;
 if new_body is null or length(btrim(new_body))=0 or length(new_body)>4000 then raise exception 'Messages must contain 1–4000 characters';end if;
 update public.chat_messages set body=btrim(new_body),edited_at=now() where id=message_id and author=auth.uid() and not deleted;
 if not found then raise exception 'Only the author can edit an available message';end if;
end$$;
create or replace function public.delete_chat_message(message_id bigint) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_member() then raise exception 'Active membership required';end if;
 update public.chat_messages set body='',deleted=true,edited_at=now() where id=message_id and (author=auth.uid() or public.is_admin()) and not deleted;
 if not found then raise exception 'Message unavailable or permission denied';end if;
end$$;
revoke all on function public.check_chat_reply(),public.edit_chat_message(bigint,text),public.delete_chat_message(bigint) from public;
grant execute on function public.edit_chat_message(bigint,text),public.delete_chat_message(bigint) to authenticated;
insert into public.chat_channels(name,description) values
 ('general','Team updates, quick questions, and everyday conversation.'),
 ('base-design','Habitat, layout, structures, and systems integration.'),
 ('research','Sources, calculations, and technical discoveries.'),
 ('mission-planning','Meetings, deadlines, deliverables, and next steps.'),
 ('off-topic','A little space for everything else.') on conflict(name) do nothing;
do $$ begin
 if not exists(select 1 from pg_publication where pubname='supabase_realtime') then create publication supabase_realtime;end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='chat_messages') then alter publication supabase_realtime add table public.chat_messages;end if;
end $$;
commit;
