import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../db/supabaseAdmin.js";

type AgentRole = "shopkeeper" | "smuggler" | "investor" | "thief" | "gig_worker" | "unemployed";

type ArenaAgent = {
  id: string;
  name: string;
  generation: number;
  ambition: number | string;
  risk_tolerance: number | string;
  role: AgentRole;
  low_wealth_streak: number;
};

type ArenaUpdate = {
  agentId: string;
  action: "birth" | "death" | "low_wealth_streak";
  details: Record<string, unknown>;
};

export type ArenaTickResult = {
  tickId: string;
  agentsProcessed: number;
  births: number;
  deaths: number;
  updates: ArenaUpdate[];
};

const REPRODUCTION_THRESHOLD = 50_000;
const SURVIVAL_THRESHOLD = 1_000;
const SEED_WEALTH = 10_000;
const MUTATION_RANGE = 0.1;
const DEATH_STREAK = 3;

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

function mutateTrait(value: number | string): number {
  const base = Number(value);
  const delta = (Math.random() - 0.5) * MUTATION_RANGE * 2;
  return Number(clamp01(base + delta).toFixed(4));
}

function childName(parent: ArenaAgent): string {
  return `${parent.name} G${parent.generation + 1}-${randomUUID().slice(0, 4)}`;
}

async function readAgentWealth(agentId: string): Promise<number> {
  const { data, error } = await supabaseAdmin.rpc("agent_total_wealth", {
    p_agent_id: agentId,
  });

  if (error) {
    throw new Error(`Agent wealth failed for ${agentId}: ${error.message}`);
  }

  return Number(data ?? 0);
}

async function maybeSpawnChild(
  agent: ArenaAgent,
  totalWealth: number,
  tickId: string,
): Promise<ArenaUpdate | null> {
  if (totalWealth < REPRODUCTION_THRESHOLD) {
    return null;
  }

  const childAmbition = mutateTrait(agent.ambition);
  const childRisk = mutateTrait(agent.risk_tolerance);

  const { data, error } = await supabaseAdmin.rpc("spawn_agent", {
    p_parent_agent_id: agent.id,
    p_child_name: childName(agent),
    p_child_ambition: childAmbition,
    p_child_risk_tolerance: childRisk,
    p_child_role: agent.role,
    p_seed_wealth: SEED_WEALTH,
    p_tick_id: tickId,
    p_reproduction_threshold: REPRODUCTION_THRESHOLD,
  });

  if (error) {
    throw new Error(`Agent spawn failed for ${agent.id}: ${error.message}`);
  }

  if (!data?.success) {
    return null;
  }

  return {
    agentId: agent.id,
    action: "birth",
    details: {
      childAgentId: data.child_agent_id,
      generation: data.generation,
      cost: data.cost,
      wealthSnapshot: data.wealth_snapshot,
    },
  };
}

async function applySurvivalState(
  agent: ArenaAgent,
  totalWealth: number,
  tickId: string,
): Promise<ArenaUpdate | null> {
  const { data, error } = await supabaseAdmin.rpc("apply_agent_survival_state", {
    p_agent_id: agent.id,
    p_total_wealth: totalWealth,
    p_tick_id: tickId,
    p_survival_threshold: SURVIVAL_THRESHOLD,
    p_death_streak: DEATH_STREAK,
  });

  if (error) {
    throw new Error(`Agent survival update failed for ${agent.id}: ${error.message}`);
  }

  if (!data?.success) {
    return null;
  }

  if (data.died === true) {
    return {
      agentId: agent.id,
      action: "death",
      details: {
        wealthSnapshot: totalWealth,
        lowWealthStreak: data.low_wealth_streak,
      },
    };
  }

  if (totalWealth < SURVIVAL_THRESHOLD) {
    return {
      agentId: agent.id,
      action: "low_wealth_streak",
      details: {
        wealthSnapshot: totalWealth,
        lowWealthStreak: data.low_wealth_streak,
      },
    };
  }

  return null;
}

export async function arenaTick(): Promise<ArenaTickResult> {
  const tickId = randomUUID();
  const updates: ArenaUpdate[] = [];

  const { data, error } = await supabaseAdmin
    .from("agents")
    .select("id, name, generation, ambition, risk_tolerance, role, low_wealth_streak")
    .eq("active", true)
    .eq("status", "active")
    .order("created_at", { ascending: true });

  if (error) {
    throw new Error(`Failed to fetch arena agents: ${error.message}`);
  }

  const agents = (data ?? []) as ArenaAgent[];

  for (const agent of agents) {
    const totalWealth = await readAgentWealth(agent.id);

    const birth = await maybeSpawnChild(agent, totalWealth, tickId);
    if (birth) {
      updates.push(birth);
    }

    const survival = await applySurvivalState(agent, totalWealth, tickId);
    if (survival) {
      updates.push(survival);
    }
  }

  return {
    tickId,
    agentsProcessed: agents.length,
    births: updates.filter((update) => update.action === "birth").length,
    deaths: updates.filter((update) => update.action === "death").length,
    updates,
  };
}
