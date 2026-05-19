export type EngineConfig = {
  nodeEnv: string;
  port: number;
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
  tickSecret: string;
  marketDamping: number;
};

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function readNumber(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }

  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw new Error(`${name} must be a finite number`);
  }

  return value;
}

export function loadConfig(): EngineConfig {
  return {
    nodeEnv: process.env.NODE_ENV ?? "development",
    port: readNumber("PORT", 3000),
    supabaseUrl: requireEnv("SUPABASE_URL"),
    supabaseServiceRoleKey: requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    tickSecret: requireEnv("TICK_SECRET"),
    marketDamping: readNumber("MARKET_DAMPING", 0.05),
  };
}

