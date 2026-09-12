import { DurableObject } from "cloudflare:workers";

interface Env {
  FEED_STATE: DurableObjectNamespace<FeedState>;
  GITHUB_DISPATCH_TOKEN: string;
  GITHUB_REPOSITORY: string;
}

const SOURCES = [
  { name: "ipsw.me RSS", url: "https://ipsw.me/timeline.rss", select: (body: string) => body },
  { name: "ipsw.dev beta", url: "https://www.ipsw.dev/", select: (body: string) => [...body.matchAll(/href="\/build\/([A-Za-z0-9]+)".*?<h3[^>]*>([^<]+)/gs)].map((m) => `${m[1]}:${m[2].trim()}`).join("\n") },
  { name: "ipswbeta.dev", url: "https://ipswbeta.dev/", select: (body: string) => [...body.matchAll(/href="\/(ios|ipados|macos|tvos|visionos)\/([0-9]+\.x)\//g)].map((m) => `${m[1]}:${m[2]}`).sort().join("\n") },
];

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
  async check(): Promise<{ changed: boolean; initial: boolean }> {
    const current = await fingerprint();
    const previous = await this.ctx.storage.get<string>("fingerprint");
    if (!previous) {
      await this.ctx.storage.put("fingerprint", current.value);
      await this.ctx.storage.put("checked_at", new Date().toISOString());
      return { changed: false, initial: true };
    }
    if (previous === current.value) {
      await this.ctx.storage.put("checked_at", new Date().toISOString());
      return { changed: false, initial: false };
    }

    // Persist the candidate before sending.  A duplicate dispatch is harmless:
    // the catalog workflow itself is serialized and commits only actual changes.
    await this.ctx.storage.put("pending_fingerprint", current.value);
    const response = await fetch(`https://api.github.com/repos/${this.env.GITHUB_REPOSITORY}/dispatches`, {
      method: "POST",
      headers: {
        "Accept": "application/vnd.github+json",
        "Authorization": `Bearer ${this.env.GITHUB_DISPATCH_TOKEN}`,
        "User-Agent": "ipsw-link-catalog-feed-relay/1.0",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify({ event_type: "firmware_release", client_payload: { sources: current.sources } }),
    });
    if (!response.ok) throw new Error(`GitHub repository_dispatch: HTTP ${response.status}`);
    await this.ctx.storage.put("fingerprint", current.value);
    await this.ctx.storage.delete("pending_fingerprint");
    await this.ctx.storage.put("checked_at", new Date().toISOString());
    return { changed: true, initial: false };
  }

  async status(): Promise<Record<string, unknown>> {
    return {
      fingerprint_initialized: Boolean(await this.ctx.storage.get("fingerprint")),
      checked_at: await this.ctx.storage.get("checked_at"),
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
