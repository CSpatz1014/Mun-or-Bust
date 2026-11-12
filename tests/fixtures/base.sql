-- Run once in a NEW Supabase project's SQL Editor.
begin;
create table public.invites(email text primary key check(email=lower(email)), role text not null default 'member' check(role in ('member','mentor','admin')),created_at timestamptz not null default now());
create table public.profiles(id uuid primary key references auth.users on delete cascade,name text not null check(length(name) between 1 and 80),focus text default '' check(length(focus)<=200),bio text default '' check(length(bio)<=2000),role text not null check(role in ('member','mentor','admin')),active boolean not null default true,created_at timestamptz not null default now());
create function public.is_member() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.profiles where id=auth.uid() and active)$$;
create function public.is_admin() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.profiles where id=auth.uid() and active and role='admin')$$;
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$declare assigned text;begin
 select role into assigned from public.invites where email=lower(new.email);
 if assigned is null then raise exception 'This email has not been invited. Contact your team admin.';end if;
 insert into public.profiles(id,name,role) values(new.id,split_part(new.email,'@',1),assigned);
 return new;end$$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
create function public.manage_member(target uuid,new_role text,new_active boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.is_admin() then raise exception 'Admin access required';end if;
 if new_role not in ('member','mentor','admin') or new_active is null then raise exception 'Invalid membership';end if;
 -- Serialize membership changes so two admins cannot concurrently remove the last admin.
 perform pg_advisory_xact_lock(764821);
 if not public.is_admin() then raise exception 'Admin access required';end if;
 if target=auth.uid() and (new_role<>'admin' or not new_active) then raise exception 'Ask another admin to change your own access';end if;
 if exists(select 1 from public.profiles where id=target and role='admin' and active) and (new_role<>'admin' or not new_active) and (select count(*) from public.profiles where active and role='admin')<=1 then raise exception 'Keep at least one active admin';end if;
 update public.profiles set role=new_role,active=new_active where id=target;
 if not found then raise exception 'Member not found';end if;
end$$;
create table public.tasks(id uuid primary key default gen_random_uuid(),title text not null check(length(title) between 1 and 160),description text default '' check(length(description)<=5000),kind text not null default 'task' check(kind in ('task','deadline')),status text not null default 'To do' check(status in ('To do','In progress','Done')),priority text not null default 'Normal' check(priority in ('Low','Normal','High')),due_at timestamptz,due_date date,assignee uuid references public.profiles on delete set null,author uuid references public.profiles on delete set null,created_at timestamptz not null default now(),check(due_at is null or due_date is null));
create table public.ideas(id uuid primary key default gen_random_uuid(),title text not null check(length(title) between 1 and 160),body text not null check(length(body)<=10000),tag text not null default 'Other',author uuid not null references public.profiles on delete cascade,attachment text,attachment_type text,created_at timestamptz not null default now());
create table public.comments(id uuid primary key default gen_random_uuid(),idea_id uuid not null references public.ideas on delete cascade,body text not null check(length(body) between 1 and 3000),author uuid not null references public.profiles on delete cascade,created_at timestamptz not null default now());
create index on public.comments(idea_id);create index on public.tasks(assignee);
alter table public.invites enable row level security;alter table public.profiles enable row level security;alter table public.tasks enable row level security;alter table public.ideas enable row level security;alter table public.comments enable row level security;
revoke all on public.invites,public.profiles,public.tasks,public.ideas,public.comments from anon,authenticated;
grant select,insert,update,delete on public.invites to authenticated;
grant select on public.profiles to authenticated;
grant update(name,focus,bio) on public.profiles to authenticated;
grant select,insert,update,delete on public.tasks,public.ideas,public.comments to authenticated;
create policy invites_admin on public.invites for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy profiles_read on public.profiles for select to authenticated using(public.is_member());
create policy profiles_self on public.profiles for update to authenticated using(id=auth.uid() and public.is_member()) with check(id=auth.uid() and public.is_member());
create policy tasks_read on public.tasks for select to authenticated using(public.is_member());
create policy tasks_insert on public.tasks for insert to authenticated with check(public.is_member() and author=auth.uid());
create policy tasks_update on public.tasks for update to authenticated using(public.is_member()) with check(public.is_member());
create policy tasks_delete on public.tasks for delete to authenticated using(public.is_member());
create policy ideas_read on public.ideas for select to authenticated using(public.is_member());
create policy ideas_insert on public.ideas for insert to authenticated with check(public.is_member() and author=auth.uid() and (attachment is null or split_part(attachment,'/',1)=auth.uid()::text));
create policy ideas_update on public.ideas for update to authenticated using(public.is_member() and (author=auth.uid() or public.is_admin())) with check(public.is_member() and (author=auth.uid() or public.is_admin()));
create policy ideas_delete on public.ideas for delete to authenticated using(public.is_member() and (author=auth.uid() or public.is_admin()));
create policy comments_read on public.comments for select to authenticated using(public.is_member());
create policy comments_insert on public.comments for insert to authenticated with check(public.is_member() and author=auth.uid());
create policy comments_delete on public.comments for delete to authenticated using(public.is_member() and (author=auth.uid() or public.is_admin()));
revoke all on function public.handle_new_user(),public.manage_member(uuid,text,boolean),public.is_member(),public.is_admin() from public;
grant execute on function public.manage_member(uuid,text,boolean),public.is_member(),public.is_admin() to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('drawings','drawings',false,5242880,array['image/png','image/jpeg','image/webp','application/pdf']);
create policy drawings_read on storage.objects for select to authenticated using(bucket_id='drawings' and public.is_member());
create policy drawings_upload on storage.objects for insert to authenticated with check(bucket_id='drawings' and public.is_member() and (storage.foldername(name))[1]=auth.uid()::text);
create policy drawings_delete on storage.objects for delete to authenticated using(bucket_id='drawings' and public.is_member() and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));
commit;
-- Next, authorize yourself before signing up (replace the email):
-- insert into public.invites(email,role) values('YOUR-LOWERCASE-EMAIL@example.com','admin');
