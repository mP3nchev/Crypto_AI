// Magic-link login (spec P-22). Sign-ups are disabled in Supabase Auth; only the invited user can sign in.
import { useState, type FormEvent } from 'react';
import { supabase, supabaseConfigured } from '../lib/supabase';

export function Login({ expired }: { expired: boolean }) {
  const [email, setEmail] = useState('');
  const [state, setState] = useState<'idle' | 'sending' | 'sent' | 'error'>('idle');
  const [msg, setMsg] = useState('');

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!supabase) return;
    setState('sending');
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { shouldCreateUser: false, emailRedirectTo: window.location.origin },
    });
    if (error) { setState('error'); setMsg(error.message); } else setState('sent');
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4">
      <div className="w-full max-w-sm bg-surface border border-borderSubtle rounded-2xl shadow-2xl overflow-hidden">
        <div className="p-6 border-b border-borderSubtle bg-obsidian/60 flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-electricBlue to-indigo-600 flex items-center justify-center shadow-lg shadow-electricBlue/20">
            <i className="fa-solid fa-wave-square text-white text-lg" aria-hidden />
          </div>
          <div>
            <h1 className="text-lg font-bold text-white">Crypto AI</h1>
            <p className="text-xs text-slate-400">Paper Trading Dashboard</p>
          </div>
        </div>
        <div className="p-6">
          {!supabaseConfigured ? (
            <p className="text-sm text-crimsonNeon">Missing configuration: set <code className="font-mono">VITE_SUPABASE_URL</code> and <code className="font-mono">VITE_SUPABASE_ANON_KEY</code> (see .env.example).</p>
          ) : state === 'sent' ? (
            <div className="text-sm text-slate-300 space-y-2">
              <p className="flex items-center gap-2 text-emeraldNeon font-semibold"><i className="fa-solid fa-envelope-circle-check" aria-hidden />Check your inbox</p>
              <p className="text-xs text-slate-400">A sign-in link was sent to <span className="font-mono text-slate-200">{email}</span>. Open it in this browser.</p>
              <button onClick={() => setState('idle')} className="text-xs text-electricBlue hover:underline cursor-pointer">Use another email</button>
            </div>
          ) : (
            <form onSubmit={submit} className="space-y-4">
              {expired && <p className="text-xs text-amberWarn bg-amberWarn/10 border border-amberWarn/30 rounded-lg px-3 py-2">Your session expired. Please sign in again.</p>}
              <div>
                <label htmlFor="email" className="block text-[11px] font-semibold uppercase tracking-wider text-slate-400 mb-1.5">Email</label>
                <input id="email" type="email" required autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)}
                  className="w-full bg-obsidian border border-borderSubtle focus:border-electricBlue rounded-xl px-3 py-2.5 text-sm text-white focus:outline-none" />
              </div>
              {state === 'error' && <p className="text-xs text-crimsonNeon">{msg}</p>}
              <button type="submit" disabled={state === 'sending'}
                className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-electricBlue hover:bg-blue-600 disabled:opacity-60 text-white text-sm font-semibold shadow-lg shadow-electricBlue/25 cursor-pointer">
                <i className="fa-solid fa-wand-magic-sparkles" aria-hidden />{state === 'sending' ? 'Sending…' : 'Send magic link'}
              </button>
              <p className="text-[11px] text-slate-500">Access is limited to the invited account. No data is shown without signing in.</p>
            </form>
          )}
        </div>
      </div>
    </div>
  );
}
