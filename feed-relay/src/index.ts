import { DurableObject } from "cloudflare:workers";

interface Env {
  FEED_STATE: DurableObjectNamespace<FeedState>;
  PUSH_SUBSCRIPTIONS: DurableObjectNamespace<PushSubscriptions>;
  DEVICE_TOKENS: DurableObjectNamespace<DeviceTokens>;
  GITHUB_DISPATCH_TOKEN: string;
  PUSH_API_TOKEN: string;
  GITHUB_REPOSITORY: string;
  VAPID_PUBLIC_KEY: string;
}

type PushSubscriptionRecord = {
  endpoint: string;
  expirationTime: number | null;
  keys: { auth: string; p256dh: string };
};

const SITE_ORIGIN = "https://4ge6n.github.io";

const SOURCES = [
  // Apple's own version feed: small, official, and it changes the moment a
  // build ships, ahead of any third party indexing the restore images.
  {
    name: "Apple gdmf product versions",
    url: "https://gdmf.apple.com/v2/pmv",
    select: (body: string) => {
      const parsed = JSON.parse(body) as Record<string, Record<string, { ProductVersion?: string; Build?: string }[]>>;
      const lines: string[] = [];
      for (const group of ["PublicAssetSets", "AssetSets"]) {
        for (const [platform, entries] of Object.entries(parsed[group] ?? {})) {
          for (const entry of entries ?? []) lines.push(`${group}/${platform}:${entry.ProductVersion}:${entry.Build}`);
        }
      }
      return lines.sort().join("\n");
    },
  },
  { name: "Apple Developer Releases RSS", url: "https://developer.apple.com/news/releases/rss/releases.rss", select: (body: string) => body },
  { name: "ipsw.me RSS", url: "https://ipsw.me/timeline.rss", select: (body: string) => body },
  { name: "ipsw.dev beta", url: "https://www.ipsw.dev/", select: (body: string) => [...body.matchAll(/href="\/build\/([A-Za-z0-9]+)".*?<h3[^>]*>([^<]+)/gs)].map((m) => `${m[1]}:${m[2].trim()}`).join("\n") },
  { name: "ipswbeta.dev", url: "https://ipswbeta.dev/", select: (body: string) => [...body.matchAll(/href="\/(ios|ipados|macos|tvos|visionos)\/([0-9]+\.x)\//g)].map((m) => `${m[1]}:${m[2]}`).sort().join("\n") },
];
const FINGERPRINT_SCHEMA = 2;
const RETRY_DELAYS_MS = [0, 10 * 60_000, 30 * 60_000, 90 * 60_000, 6 * 60 * 60_000];

async function digest(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function fingerprint(): Promise<{ value: string; sources: string[] }> {
  const results = await Promise.all(SOURCES.map(async (source) => {
    try {
      const response = await fetch(source.url, { headers: { "User-Agent": "ipsw-link-catalog-feed-relay/1.0" } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return `${source.name}:${await digest(source.select(await response.text()))}`;
    } catch {
      // One unreachable feed must not stop the others from being checked. The
      // marker is constant, so being down does not keep changing the
      // fingerprint; coming back changes it once, which is what we want.
      return `${source.name}:unavailable`;
    }
  }));
  if (results.every((line) => line.endsWith(":unavailable"))) throw new Error("every feed is unavailable");
  return { value: await digest(results.sort().join("\n")), sources: results };
}

export class FeedState extends DurableObject<Env> {
  async check(): Promise<{ changed: boolean; initial: boolean; retry_attempt?: number }> {
    const current = await fingerprint();
    const previous = await this.ctx.storage.get<string>("fingerprint");
    const previousSchema = await this.ctx.storage.get<number>("fingerprint_schema");
    if (!previous || previousSchema !== FINGERPRINT_SCHEMA) {
      await this.ctx.storage.put("fingerprint", current.value);
      await this.ctx.storage.put("fingerprint_schema", FINGERPRINT_SCHEMA);
      await this.ctx.storage.put("checked_at", new Date().toISOString());
      return { changed: false, initial: true };
    }
    const sourceChanged = previous !== current.value;
    const now = Date.now();
    if (sourceChanged) {
      await this.ctx.storage.put("fingerprint", current.value);
      await this.ctx.storage.put("retry_attempt", 0);
      await this.ctx.storage.put("next_retry_at", now);
    }

    const attempt = await this.ctx.storage.get<number>("retry_attempt");
    const nextRetryAt = await this.ctx.storage.get<number>("next_retry_at");
    if (attempt === undefined || nextRetryAt === undefined || now < nextRetryAt) {
      await this.ctx.storage.put("checked_at", new Date().toISOString());
      return { changed: false, initial: false };
    }

    // Apple can announce a release before its CDN links reach public indexes.
    // Re-run a small, bounded sequence after a real feed change; idle polling
    // never creates GitHub Actions runs.
    await this.ctx.storage.put("pending_fingerprint", current.value);
    const response = await fetch(`https://api.github.com/repos/${this.env.GITHUB_REPOSITORY}/dispatches`, {
      method: "POST",
      headers: {
        "Accept": "application/vnd.github+json",
        "Authorization": `Bearer ${this.env.GITHUB_DISPATCH_TOKEN}`,
        "User-Agent": "ipsw-link-catalog-feed-relay/1.0",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify({ event_type: "firmware_release", client_payload: { sources: current.sources, retry_attempt: attempt } }),
    });
    if (!response.ok) {
      // A rejected dispatch used to throw here, which left checked_at unwritten
      // and made a broken token look like a relay that had stopped running.
      // Record it, keep the pending fingerprint, and try again next tick.
      await this.ctx.storage.put("last_dispatch_error", `${new Date().toISOString()} HTTP ${response.status}`);
      await this.ctx.storage.put("checked_at", new Date().toISOString());
      return { changed: sourceChanged, initial: false, retry_attempt: attempt };
    }
    await this.ctx.storage.delete("last_dispatch_error");
    await this.ctx.storage.delete("pending_fingerprint");
    const nextAttempt = attempt + 1;
    if (nextAttempt < RETRY_DELAYS_MS.length) {
      await this.ctx.storage.put("retry_attempt", nextAttempt);
      await this.ctx.storage.put("next_retry_at", now + RETRY_DELAYS_MS[nextAttempt]);
    } else {
      await this.ctx.storage.delete("retry_attempt");
      await this.ctx.storage.delete("next_retry_at");
    }
    await this.ctx.storage.put("checked_at", new Date().toISOString());
    return { changed: sourceChanged, initial: false, retry_attempt: attempt };
  }

  async status(): Promise<Record<string, unknown>> {
    return {
      fingerprint_initialized: Boolean(await this.ctx.storage.get("fingerprint")),
      checked_at: await this.ctx.storage.get("checked_at"),
      next_retry_at: await this.ctx.storage.get("next_retry_at"),
      retry_attempt: await this.ctx.storage.get("retry_attempt"),
      // Present only when GitHub last refused the dispatch, which is the one
      // failure that cannot be seen from outside the Worker otherwise.
      last_dispatch_error: await this.ctx.storage.get("last_dispatch_error"),
    };
  }
}

export class PushSubscriptions extends DurableObject<Env> {
  async subscribe(subscription: PushSubscriptionRecord): Promise<number> {
    if (!subscription.endpoint.startsWith("https://") || !subscription.keys?.auth || !subscription.keys?.p256dh) {
      throw new Error("invalid push subscription");
    }
    const subscriptions = (await this.ctx.storage.get<Record<string, PushSubscriptionRecord>>("subscriptions")) ?? {};
    subscriptions[subscription.endpoint] = subscription;
    await this.ctx.storage.put("subscriptions", subscriptions);
    return Object.keys(subscriptions).length;
  }

  async remove(endpoint: string): Promise<void> {
    const subscriptions = (await this.ctx.storage.get<Record<string, PushSubscriptionRecord>>("subscriptions")) ?? {};
    delete subscriptions[endpoint];
    await this.ctx.storage.put("subscriptions", subscriptions);
  }

  async list(): Promise<PushSubscriptionRecord[]> {
    const subscriptions = (await this.ctx.storage.get<Record<string, PushSubscriptionRecord>>("subscriptions")) ?? {};
    return Object.values(subscriptions);
  }
}

/// What one phone asked to hear about. The token is what APNs is addressed
/// with; the rest is what it wants said.
interface DeviceTokenRecord {
  token: string;
  /// Development builds and App Store builds are different APNs hosts.
  sandbox: boolean;
  /// Empty means every platform.
  platforms: string[];
  betas: boolean;
  bundle: string;
  /// The phone's own model, iPhone18,4, when it has asked to hear about that
  /// device losing its signing window. Empty when it has not asked.
  watching: string;
  updated?: number;
}

export class DeviceTokens extends DurableObject<Env> {
  async register(record: DeviceTokenRecord): Promise<number> {
    if (!/^[0-9a-f]{64,200}$/i.test(record.token ?? "")) throw new Error("invalid device token");
    if (!record.bundle) throw new Error("invalid device token");
    const tokens = (await this.ctx.storage.get<Record<string, DeviceTokenRecord>>("tokens")) ?? {};
    tokens[record.token] = {
      token: record.token,
      sandbox: Boolean(record.sandbox),
      platforms: Array.isArray(record.platforms) ? record.platforms.slice(0, 8) : [],
      betas: Boolean(record.betas),
      bundle: record.bundle,
      // One identifier, shaped like one: this is the phone saying what it is,
      // not a place to keep a list of anything.
      watching: /^[A-Za-z][A-Za-z0-9]*[0-9]+,[0-9]+$/.test(record.watching ?? "") ? record.watching : "",
      updated: Date.now(),
    };
    await this.ctx.storage.put("tokens", tokens);
    return Object.keys(tokens).length;
  }

  async remove(token: string): Promise<void> {
    const tokens = (await this.ctx.storage.get<Record<string, DeviceTokenRecord>>("tokens")) ?? {};
    delete tokens[token];
    await this.ctx.storage.put("tokens", tokens);
  }

  async list(): Promise<DeviceTokenRecord[]> {
    const tokens = (await this.ctx.storage.get<Record<string, DeviceTokenRecord>>("tokens")) ?? {};
    return Object.values(tokens);
  }
}

function cors(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", SITE_ORIGIN);
  headers.set("Access-Control-Allow-Methods", "POST, DELETE, OPTIONS");
  headers.set("Access-Control-Allow-Headers", "Content-Type");
  headers.set("Vary", "Origin");
  return new Response(response.body, { status: response.status, headers });
}

function sameOrigin(request: Request): boolean {
  return request.headers.get("Origin") === SITE_ORIGIN;
}

function authorized(request: Request, secret: string): boolean {
  const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const encoder = new TextEncoder();
  const supplied = encoder.encode(token);
  const expected = encoder.encode(secret);
  const lengthsMatch = supplied.byteLength === expected.byteLength;
  return lengthsMatch ? crypto.subtle.timingSafeEqual(supplied, expected) : !crypto.subtle.timingSafeEqual(supplied, supplied);
}

export default {
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const result = await env.FEED_STATE.getByName("firmware-feeds").check();
    console.log(JSON.stringify(result));
  },
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const subscriptions = env.PUSH_SUBSCRIPTIONS.getByName("catalog-subscribers");
    if (request.method === "OPTIONS" && url.pathname === "/subscriptions" && sameOrigin(request)) {
      return cors(new Response(null, { status: 204 }));
    }
    if (url.pathname === "/vapid-public-key" && request.method === "GET") {
      return cors(Response.json({ publicKey: env.VAPID_PUBLIC_KEY }));
    }
    const devices = env.DEVICE_TOKENS.getByName("apns-devices");
    // An app has no Origin to check. A token is only useful to whoever holds
    // the APNs key, so registering one gives nothing away.
    if (url.pathname === "/device-tokens" && request.method === "POST") {
      try {
        const count = await devices.register(await request.json<DeviceTokenRecord>());
        return Response.json({ registered: true, count }, { status: 201 });
      } catch {
        return new Response("Invalid device token", { status: 400 });
      }
    }
    if (url.pathname === "/device-tokens" && request.method === "DELETE") {
      const { token } = await request.json<{ token?: string }>();
      if (!token) return new Response("Invalid device token", { status: 400 });
      await devices.remove(token);
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/internal/device-tokens") {
      if (!authorized(request, env.PUSH_API_TOKEN)) return new Response("Unauthorized", { status: 401 });
      if (request.method === "GET") return Response.json({ devices: await devices.list() });
      if (request.method === "DELETE") {
        const { token } = await request.json<{ token?: string }>();
        if (!token) return new Response("Invalid device token", { status: 400 });
        await devices.remove(token);
        return new Response(null, { status: 204 });
      }
    }
    if (url.pathname === "/subscriptions" && request.method === "POST") {
      if (!sameOrigin(request)) return new Response("Forbidden", { status: 403 });
      try {
        const count = await subscriptions.subscribe(await request.json<PushSubscriptionRecord>());
        return cors(Response.json({ subscribed: true, count }, { status: 201 }));
      } catch {
        return cors(new Response("Invalid subscription", { status: 400 }));
      }
    }
    if (url.pathname === "/subscriptions" && request.method === "DELETE") {
      if (!sameOrigin(request)) return new Response("Forbidden", { status: 403 });
      const { endpoint } = await request.json<{ endpoint?: string }>();
      if (!endpoint) return cors(new Response("Invalid subscription", { status: 400 }));
      await subscriptions.remove(endpoint);
      return cors(new Response(null, { status: 204 }));
    }
    if (url.pathname === "/internal/subscriptions") {
      if (!authorized(request, env.PUSH_API_TOKEN)) return new Response("Unauthorized", { status: 401 });
      if (request.method === "GET") return Response.json({ subscriptions: await subscriptions.list() });
      if (request.method === "DELETE") {
        const { endpoint } = await request.json<{ endpoint?: string }>();
        if (!endpoint) return new Response("Invalid subscription", { status: 400 });
        await subscriptions.remove(endpoint);
        return new Response(null, { status: 204 });
      }
    }
    return Response.json(await env.FEED_STATE.getByName("firmware-feeds").status());
  },
} satisfies ExportedHandler<Env>;
