/*
 * SPDX-FileCopyrightText: 2026 Chausima Mail
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Chausima Mail addition: a bell in the top bar that tells the admin when the
 * server bans an IP address. It reads the same Blocked IPs list shown under
 * Settings > Security > Blocked IPs, checks it every minute, and pops a toast
 * for each new ban. Admins who cannot read that list never see the bell.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Bell, ShieldAlert } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { toast } from '@/hooks/use-toast';
import { jmapQueryAndGet, type JmapObject } from '@/services/jmap/client';

const OBJECT = 'x:BlockedIp';
const POLL_MS = 60_000;
const SEEN_KEY = 'chausima.bans.seen';
const LIST_PATH = '/Settings/x:BlockedIp';

interface Ban {
  id: string;
  ip: string;
  reason: string;
  created: number;
}

function firstString(v: unknown): string {
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v.filter((x) => typeof x === 'string').join(', ');
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return firstString(o.address ?? o.ip ?? o.value ?? o.name ?? '');
  }
  return '';
}

function pick(obj: JmapObject, test: (key: string) => boolean): unknown {
  const key = Object.keys(obj).find((k) => test(k.toLowerCase()));
  return key ? obj[key] : undefined;
}

function toBan(obj: JmapObject): Ban {
  const ip = firstString(pick(obj, (k) => k === 'address' || k === 'addresses' || k === 'ip' || k.includes('address')));
  const reason = firstString(pick(obj, (k) => k.includes('reason') || k === 'description'));
  const createdRaw = pick(obj, (k) => k.startsWith('created'));
  const created = typeof createdRaw === 'string' ? Date.parse(createdRaw) : typeof createdRaw === 'number' ? createdRaw : 0;
  return { id: String(obj.id), ip: ip || String(obj.id), reason, created: Number.isFinite(created) ? created : 0 };
}

function readSeen(): number | null {
  try {
    const v = localStorage.getItem(SEEN_KEY);
    return v === null ? null : Number(v);
  } catch {
    return null;
  }
}

function writeSeen(t: number) {
  try {
    localStorage.setItem(SEEN_KEY, String(t));
  } catch {
    /* storage unavailable: alerts still work for this visit */
  }
}

function when(t: number): string {
  if (!t) return '';
  const mins = Math.round((Date.now() - t) / 60_000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs} h ago`;
  return new Date(t).toLocaleDateString();
}

export function SecurityAlerts() {
  const navigate = useNavigate();
  const [bans, setBans] = useState<Ban[] | null>(null);
  const [seen, setSeen] = useState<number | null>(() => readSeen());
  const [available, setAvailable] = useState(true);
  const toasted = useRef<Set<string>>(new Set());
  const firstLoad = useRef(true);

  const load = useCallback(async (signal?: AbortSignal) => {
    try {
      const { list } = await jmapQueryAndGet(OBJECT, { limit: 200 }, undefined, { signal });
      const next = list.map(toBan).sort((a, b) => b.created - a.created);
      setBans(next);
      setAvailable(true);

      let base = readSeen();
      if (base === null) {
        // First time on this browser: treat existing bans as already seen.
        base = next[0]?.created ?? Date.now();
        writeSeen(base);
        setSeen(base);
      }
      const fresh = next.filter((b) => b.created > base! && !toasted.current.has(b.id));
      fresh.forEach((b) => toasted.current.add(b.id));
      if (!firstLoad.current || fresh.length <= 3) {
        fresh.slice(0, 3).forEach((b) =>
          toast({
            title: `IP banned: ${b.ip}`,
            description: b.reason || 'Blocked automatically by the server.',
            variant: 'destructive',
          }),
        );
      }
      if (firstLoad.current && fresh.length > 3) {
        toast({ title: `${fresh.length} new IP bans`, description: 'Open the bell to see them.', variant: 'destructive' });
      }
      firstLoad.current = false;
    } catch (err) {
      if ((err as { name?: string })?.name === 'AbortError') return;
      setAvailable(false);
    }
  }, []);

  useEffect(() => {
    const ctrl = new AbortController();
    const first = setTimeout(() => void load(ctrl.signal), 0);
    const timer = setInterval(() => void load(), POLL_MS);
    const onFocus = () => void load();
    window.addEventListener('focus', onFocus);
    return () => {
      ctrl.abort();
      clearTimeout(first);
      clearInterval(timer);
      window.removeEventListener('focus', onFocus);
    };
  }, [load]);

  if (!available || bans === null) return null;

  const unseen = bans.filter((b) => seen !== null && b.created > seen);
  const markSeen = () => {
    const latest = bans[0]?.created ?? Date.now();
    writeSeen(latest);
    setSeen(latest);
  };

  return (
    <DropdownMenu onOpenChange={(open) => !open && unseen.length > 0 && markSeen()}>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="relative"
          aria-label={unseen.length ? `${unseen.length} new IP bans` : 'IP bans'}
        >
          <Bell aria-hidden="true" className="h-4 w-4" />
          {unseen.length > 0 && (
            <span className="absolute right-1 top-1 grid h-4 min-w-4 place-items-center rounded-full bg-destructive px-1 text-[10px] font-bold leading-none text-destructive-foreground">
              {unseen.length > 9 ? '9+' : unseen.length}
            </span>
          )}
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-80">
        <DropdownMenuLabel>{unseen.length ? `${unseen.length} new IP ban${unseen.length > 1 ? 's' : ''}` : 'IP bans'}</DropdownMenuLabel>
        <DropdownMenuSeparator />
        {bans.length === 0 && <p className="px-2 py-3 text-sm text-muted-foreground">No banned addresses.</p>}
        {bans.slice(0, 8).map((b) => (
          <DropdownMenuItem key={b.id} className="items-start gap-2.5" onSelect={() => navigate(`${LIST_PATH}/${b.id}`)}>
            <ShieldAlert
              aria-hidden="true"
              className={`mt-0.5 h-4 w-4 shrink-0 ${seen !== null && b.created > seen ? 'text-destructive' : 'text-muted-foreground'}`}
            />
            <span className="min-w-0 flex-1">
              <span className="block truncate font-medium">{b.ip}</span>
              <span className="block truncate text-xs text-muted-foreground">
                {[b.reason, when(b.created)].filter(Boolean).join(' · ')}
              </span>
            </span>
          </DropdownMenuItem>
        ))}
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={() => navigate(LIST_PATH)}>Manage blocked IPs</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
