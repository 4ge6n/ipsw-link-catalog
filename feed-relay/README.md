# IPSW feed relay

This Cloudflare Worker polls public firmware feeds every five minutes. It stores a fingerprint in a Durable Object and sends GitHub `repository_dispatch` only when the feed content changes. The first run only stores its baseline; it does not trigger an update.

## One-time deployment

From this directory:

```bash
npx wrangler login
npx wrangler secret put GITHUB_DISPATCH_TOKEN
npx wrangler deploy
```

`GITHUB_DISPATCH_TOKEN` must be a GitHub fine-grained personal access token that can send a repository dispatch to `4ge6n/ipsw-link-catalog`. It is stored only as a Cloudflare Worker secret, never in this repository.

The Worker status URL is safe to open after deployment; it exposes only its last check time and whether its baseline has been initialized.
