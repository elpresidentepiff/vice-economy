begin;

create table public.agent_conversation_sessions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles(id) on delete cascade,
  agent_id uuid not null references public.agents(id) on delete cascade,
  district_id text not null references public.districts(district_id) on delete restrict,
  status text not null default 'active' check (status in ('active', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index agent_conversation_sessions_player_created_idx
  on public.agent_conversation_sessions (player_id, created_at desc);

create index agent_conversation_sessions_agent_created_idx
  on public.agent_conversation_sessions (agent_id, created_at desc);

create index agent_conversation_sessions_district_idx
  on public.agent_conversation_sessions (district_id);

create trigger agent_conversation_sessions_set_updated_at
before update on public.agent_conversation_sessions
for each row execute function public.set_updated_at();

create table public.agent_conversation_messages (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.agent_conversation_sessions(id) on delete cascade,
  speaker text not null check (speaker in ('player', 'agent', 'system')),
  body text not null check (length(trim(body)) > 0 and length(body) <= 4000),
  mood text,
  intent text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint agent_conversation_messages_metadata_object check (jsonb_typeof(metadata) = 'object')
);

create index agent_conversation_messages_session_created_idx
  on public.agent_conversation_messages (session_id, created_at);

create trigger agent_conversation_messages_prevent_update
before update on public.agent_conversation_messages
for each row execute function public.prevent_append_only_mutation();

create trigger agent_conversation_messages_prevent_delete
before delete on public.agent_conversation_messages
for each row execute function public.prevent_append_only_mutation();

create table public.agent_memory_events (
  id bigint generated always as identity primary key,
  agent_id uuid not null references public.agents(id) on delete cascade,
  player_id uuid references public.profiles(id) on delete cascade,
  memory_type text not null check (memory_type in ('conversation', 'deal', 'threat', 'favor', 'betrayal', 'observation')),
  salience integer not null default 1 check (salience between 1 and 10),
  summary text not null check (length(trim(summary)) > 0 and length(summary) <= 1000),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint agent_memory_events_metadata_object check (jsonb_typeof(metadata) = 'object')
);

create index agent_memory_events_agent_created_idx
  on public.agent_memory_events (agent_id, created_at desc);

create index agent_memory_events_player_created_idx
  on public.agent_memory_events (player_id, created_at desc)
  where player_id is not null;

create index agent_memory_events_player_idx
  on public.agent_memory_events (player_id);

create trigger agent_memory_events_prevent_update
before update on public.agent_memory_events
for each row execute function public.prevent_append_only_mutation();

create trigger agent_memory_events_prevent_delete
before delete on public.agent_memory_events
for each row execute function public.prevent_append_only_mutation();

create table public.agent_dialogue_events (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.agent_conversation_sessions(id) on delete cascade,
  agent_id uuid not null references public.agents(id) on delete cascade,
  player_id uuid not null references public.profiles(id) on delete cascade,
  provider text not null default 'local',
  model text,
  prompt_tokens integer,
  completion_tokens integer,
  response_id text,
  created_at timestamptz not null default now()
);

create index agent_dialogue_events_session_created_idx
  on public.agent_dialogue_events (session_id, created_at desc);

create index agent_dialogue_events_agent_created_idx
  on public.agent_dialogue_events (agent_id, created_at desc);

create index agent_dialogue_events_player_idx
  on public.agent_dialogue_events (player_id);

create trigger agent_dialogue_events_prevent_update
before update on public.agent_dialogue_events
for each row execute function public.prevent_append_only_mutation();

create trigger agent_dialogue_events_prevent_delete
before delete on public.agent_dialogue_events
for each row execute function public.prevent_append_only_mutation();

alter table public.agent_conversation_sessions enable row level security;
alter table public.agent_conversation_messages enable row level security;
alter table public.agent_memory_events enable row level security;
alter table public.agent_dialogue_events enable row level security;

create policy "agent_conversation_sessions_select_own"
on public.agent_conversation_sessions
for select
to authenticated
using (player_id = auth.uid());

create policy "agent_conversation_sessions_service_select"
on public.agent_conversation_sessions
for select
to service_role
using (true);

create policy "agent_conversation_sessions_service_insert"
on public.agent_conversation_sessions
for insert
to service_role
with check (true);

create policy "agent_conversation_sessions_service_update"
on public.agent_conversation_sessions
for update
to service_role
using (true)
with check (true);

create policy "agent_conversation_messages_select_own"
on public.agent_conversation_messages
for select
to authenticated
using (
  exists (
    select 1
    from public.agent_conversation_sessions s
    where s.id = session_id
      and s.player_id = auth.uid()
  )
);

create policy "agent_conversation_messages_service_select"
on public.agent_conversation_messages
for select
to service_role
using (true);

create policy "agent_conversation_messages_service_insert"
on public.agent_conversation_messages
for insert
to service_role
with check (true);

create policy "agent_memory_events_select_own"
on public.agent_memory_events
for select
to authenticated
using (player_id = auth.uid());

create policy "agent_memory_events_service_select"
on public.agent_memory_events
for select
to service_role
using (true);

create policy "agent_memory_events_service_insert"
on public.agent_memory_events
for insert
to service_role
with check (true);

create policy "agent_dialogue_events_service_select"
on public.agent_dialogue_events
for select
to service_role
using (true);

create policy "agent_dialogue_events_service_insert"
on public.agent_dialogue_events
for insert
to service_role
with check (true);

revoke all on table public.agent_conversation_sessions from anon, authenticated, service_role;
revoke all on table public.agent_conversation_messages from anon, authenticated, service_role;
revoke all on table public.agent_memory_events from anon, authenticated, service_role;
revoke all on table public.agent_dialogue_events from anon, authenticated, service_role;

grant select on table public.agent_conversation_sessions to authenticated;
grant select on table public.agent_conversation_messages to authenticated;
grant select on table public.agent_memory_events to authenticated;

grant select, insert, update on table public.agent_conversation_sessions to service_role;
grant select, insert on table public.agent_conversation_messages to service_role;
grant select, insert on table public.agent_memory_events to service_role;
grant select, insert on table public.agent_dialogue_events to service_role;

revoke all on sequence public.agent_conversation_messages_id_seq from anon, authenticated;
revoke all on sequence public.agent_memory_events_id_seq from anon, authenticated;
revoke all on sequence public.agent_dialogue_events_id_seq from anon, authenticated;

grant usage, select on sequence public.agent_conversation_messages_id_seq to service_role;
grant usage, select on sequence public.agent_memory_events_id_seq to service_role;
grant usage, select on sequence public.agent_dialogue_events_id_seq to service_role;

commit;
