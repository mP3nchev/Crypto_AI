import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

/**
 * LOCAL DEVELOPMENT ONLY: a pre-signed `authenticated` JWT for a local test
 * database. Ignored in production builds (import.meta.env.DEV is false there),
 * so it can never bypass the login on the deployed site.
 */
const devAccessToken = import.meta.env.DEV
  ? (import.meta.env.VITE_DEV_ACCESS_TOKEN as string | undefined)
  : undefined;

export const supabaseConfigured = Boolean(url && anonKey);
export const usingDevToken = Boolean(devAccessToken);

export const supabase: SupabaseClient | null = supabaseConfigured
  ? createClient(
      url!,
      anonKey!,
      devAccessToken
        ? { accessToken: async () => devAccessToken }
        : { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } },
    )
  : null;

export function requireClient(): SupabaseClient {
  if (!supabase) throw new Error('Supabase is not configured (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY).');
  return supabase;
}
