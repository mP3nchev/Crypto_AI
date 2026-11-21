import { useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase, usingDevToken } from '../lib/supabase';
import { SESSION_EXPIRED_EVENT } from '../lib/api';

export type SessionState =
  | { status: 'loading' }
  | { status: 'signed-out'; expired: boolean }
  | { status: 'signed-in'; email: string | null };

export function useSession(): SessionState {
  const [state, setState] = useState<SessionState>(
    usingDevToken ? { status: 'signed-in', email: 'local-dev' } : { status: 'loading' },
  );

  useEffect(() => {
    if (usingDevToken || !supabase) {
      if (!supabase) setState({ status: 'signed-out', expired: false });
      return;
    }
    const apply = (s: Session | null, expired = false) =>
      setState(s ? { status: 'signed-in', email: s.user.email ?? null } : { status: 'signed-out', expired });

    supabase.auth.getSession().then(({ data }) => apply(data.session));
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => apply(s));

    const onExpired = () => {
      supabase!.auth.signOut({ scope: 'local' }).finally(() => apply(null, true));
    };
    window.addEventListener(SESSION_EXPIRED_EVENT, onExpired);
    return () => {
      sub.subscription.unsubscribe();
      window.removeEventListener(SESSION_EXPIRED_EVENT, onExpired);
    };
  }, []);

  return state;
}
