begin;

create index if not exists agent_conversation_sessions_district_idx
  on public.agent_conversation_sessions (district_id);

create index if not exists agent_memory_events_player_idx
  on public.agent_memory_events (player_id);

create index if not exists agent_dialogue_events_player_idx
  on public.agent_dialogue_events (player_id);

commit;
