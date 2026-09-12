import { DurableObject } from "cloudflare:workers";

interface Env {
  FEED_STATE: DurableObjectNamespace<FeedState>;
  GITHUB_DISPATCH_TOKEN: string;
  GITHUB_REPOSITORY: string;
}

const SOURCES = [
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
    const response = await fetch(source.url, { headers: { "User-Agent": "ipsw-link-catalog-feed-relay/1.0" } });
    if (!response.ok) throw new Error(`${source.name}: HTTP ${response.status}`);
    return `${source.name}:${await digest(source.select(await response.text()))}`;
  }));
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
    if (!response.ok) throw new Error(`GitHub repository_dispatch: HTTP ${response.status}`);
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
    };
  }
}

export default {
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const result = await env.FEED_STATE.getByName("firmware-feeds").check();
    console.log(JSON.stringify(result));
  },
  async fetch(_request: Request, env: Env): Promise<Response> {
    return Response.json(await env.FEED_STATE.getByName("firmware-feeds").status());
  },
} satisfies ExportedHandler<Env>;
