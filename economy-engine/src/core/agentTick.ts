import { randomUUID } from "node:crypto";
import { supabaseAdmin } from "../db/supabaseAdmin.js";

type AgentRole = "shopkeeper" | "smuggler" | "investor" | "thief" | "gig_worker" | "unemployed";

type Agent = {
  id: string;
  name: string;
  district_id: string;
  role: AgentRole;
  ambition: number | string;
  risk_tolerance: number | string;
  current_goal: string | null;
};

type District = {
  district_id: string;
  heat_level: number;
  crime_pressure: number;
  demand_multiplier: number | string;
};

type AgentBalance = {
  agent_id: string;
  cash_clean: number;
  cash_dirty: number;
};

type AgentInventory = {
  agent_id: string;
  item_id: string;
  quantity: number;
};

type AgentTickAction = {
  agentId: string;
  action: string;
  details: Record<string, unknown>;
};

export type AgentTickResult = {
  tickId: string;
  agentsProcessed: number;
  actions: number;
  updates: AgentTickAction[];
};

const ESSENTIAL_ITEMS = ["water_bottle", "street_taco"] as const;

function inventoryKey(agentId: string, itemId: string): string {
  return `${agentId}:${itemId}`;
}

function saferDistrictFor(agent: Agent, district: District): string | null {
  if (district.heat_level <= 70 || Number(agent.ambition) <= 0.5) {
    return null;
  }

  switch (agent.district_id) {
    case "port":
    case "swamp":
    case "downtown":
      return "suburbs";
    case "vice_beach":
      return "downtown";
    default:
      return null;
  }
}

async function buyItem(
  agent: Agent,
  itemId: string,
  tickId: string,
  reason: string,
): Promise<AgentTickAction | null> {
  const { data, error } = await supabaseAdmin.rpc("agent_purchase_item", {
    p_agent_id: agent.id,
    p_item_id: itemId,
    p_quantity: 1,
    p_tick_id: tickId,
    p_reason: reason,
  });

  if (error) {
    throw new Error(`Agent purchase failed for ${agent.id}/${itemId}: ${error.message}`);
  }

  if (!data?.success) {
    return null;
  }

  return {
    agentId: agent.id,
    action: reason,
    details: {
      itemId,
      cost: data.cost,
    },
  };
}

async function applyIncome(agent: Agent, tickId: string): Promise<AgentTickAction | null> {
  const amount = agent.role === "shopkeeper" ? 900 : 500;
  const { data, error } = await supabaseAdmin.rpc("apply_agent_cash_delta", {
    p_agent_id: agent.id,
    p_delta_amount: amount,
    p_currency: "cash_clean",
    p_reason: "gig_income",
    p_tick_id: tickId,
    p_details: {
      role: agent.role,
    },
  });

  if (error) {
    throw new Error(`Agent income failed for ${agent.id}: ${error.message}`);
  }

  if (data !== true) {
    return null;
  }

  return {
    agentId: agent.id,
    action: "gig_income",
    details: {
      amount,
      currency: "cash_clean",
    },
  };
}

async function migrateAgent(
  agent: Agent,
  fromDistrictId: string,
  toDistrictId: string,
  tickId: string,
): Promise<AgentTickAction | null> {
  const { data, error } = await supabaseAdmin.rpc("apply_agent_migration", {
    p_agent_id: agent.id,
    p_from_district_id: fromDistrictId,
    p_to_district_id: toDistrictId,
    p_tick_id: tickId,
  });

  if (error) {
    throw new Error(`Agent migration failed for ${agent.id}: ${error.message}`);
  }

  if (data !== true) {
    return null;
  }

  return {
    agentId: agent.id,
    action: "migrate",
    details: {
      from: fromDistrictId,
      to: toDistrictId,
    },
  };
}

export async function agentTick(): Promise<AgentTickResult> {
  const tickId = randomUUID();

  const { data: agentData, error: agentError } = await supabaseAdmin
    .from("agents")
    .select("id, name, district_id, role, ambition, risk_tolerance, current_goal")
    .eq("active", true)
    .order("created_at", { ascending: true });

  if (agentError) {
    throw new Error(`Failed to fetch agents: ${agentError.message}`);
  }

  const { data: districtData, error: districtError } = await supabaseAdmin
    .from("districts")
    .select("district_id, heat_level, crime_pressure, demand_multiplier");

  if (districtError) {
    throw new Error(`Failed to fetch districts for agents: ${districtError.message}`);
  }

  const { data: balanceData, error: balanceError } = await supabaseAdmin
    .from("agent_wallet_balances")
    .select("agent_id, cash_clean, cash_dirty");

  if (balanceError) {
    throw new Error(`Failed to fetch agent balances: ${balanceError.message}`);
  }

  const { data: inventoryData, error: inventoryError } = await supabaseAdmin
    .from("agent_inventory")
    .select("agent_id, item_id, quantity");

  if (inventoryError) {
    throw new Error(`Failed to fetch agent inventory: ${inventoryError.message}`);
  }

  const agents = (agentData ?? []) as Agent[];
  const districts = new Map(
    ((districtData ?? []) as District[]).map((district) => [district.district_id, district]),
  );
  const balances = new Map(
    ((balanceData ?? []) as AgentBalance[]).map((balance) => [balance.agent_id, balance]),
  );
  const inventory = new Map(
    ((inventoryData ?? []) as AgentInventory[]).map((entry) => [
      inventoryKey(entry.agent_id, entry.item_id),
      Number(entry.quantity),
    ]),
  );
  const updates: AgentTickAction[] = [];

  for (const agent of agents) {
    const district = districts.get(agent.district_id);
    if (!district) {
      continue;
    }

    const balance = balances.get(agent.id) ?? {
      agent_id: agent.id,
      cash_clean: 0,
      cash_dirty: 0,
    };
    let cleanCash = Number(balance.cash_clean);

    if (cleanCash < 1000 && (agent.role === "gig_worker" || agent.role === "unemployed" || agent.role === "shopkeeper")) {
      const income = await applyIncome(agent, tickId);
      if (income) {
        updates.push(income);
        cleanCash += Number(income.details.amount ?? 0);
      }
    }

    for (const itemId of ESSENTIAL_ITEMS) {
      const hasItem = (inventory.get(inventoryKey(agent.id, itemId)) ?? 0) > 0;
      if (!hasItem && cleanCash > 100) {
        const purchase = await buyItem(agent, itemId, tickId, "buy_essential");
        if (purchase) {
          updates.push(purchase);
          cleanCash -= Number(purchase.details.cost ?? 0);
        }
      }
    }

    if (Number(agent.ambition) > 0.65 && cleanCash > 5000 && agent.role !== "shopkeeper") {
      const purchase = await buyItem(agent, "burner_phone", tickId, "speculative_buy");
      if (purchase) {
        updates.push(purchase);
      }
    }

    const toDistrictId = saferDistrictFor(agent, district);
    if (toDistrictId) {
      const migration = await migrateAgent(agent, agent.district_id, toDistrictId, tickId);
      if (migration) {
        updates.push(migration);
      }
    }
  }

  return {
    tickId,
    agentsProcessed: agents.length,
    actions: updates.length,
    updates,
  };
}
