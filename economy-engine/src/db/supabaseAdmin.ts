import { createClient } from "@supabase/supabase-js";
import { loadConfig } from "../config.js";

const config = loadConfig();

export const supabaseAdmin = createClient(
  config.supabaseUrl,
  config.supabaseServiceRoleKey,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  },
);

