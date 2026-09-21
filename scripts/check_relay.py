"""Fail the run when the relay cannot start one.

The relay watches Apple and asks GitHub to run this workflow the moment
something appears. If GitHub refuses — an expired dispatch token — the relay
has nowhere to say so, and the first sign is a notification that never
arrives. This is that sign, an hour earlier and addressed to someone who can
act on it.
"""
import datetime, json, sys, urllib.request

RELAY = "https://ipsw-link-catalog-feed-relay.shigelon.workers.dev/status"
# The relay looks every five minutes; six times that is not a slow minute.
STALE_MINUTES = 30

def main() -> int:
    # Cloudflare answers 403 to a request with no user agent of its own.
    request = urllib.request.Request(RELAY, headers={"User-Agent": "ipsw-link-catalog/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            status = json.load(response)
    except Exception as failure:
        # A relay that cannot be reached from here may still be reaching
        # Apple and GitHub, so this is a warning rather than a verdict.
        print(f"::warning::The relay did not answer ({failure}); its health is unknown.")
        return 0

    print(json.dumps(status))
    error = status.get("last_dispatch_error")
    if error:
        print(f"::error::The relay cannot start this workflow: {error}. Real-time "
              "notifications are down until the dispatch token is renewed "
              "(wrangler secret put GITHUB_DISPATCH_TOKEN).")
        return 1

    checked = status.get("checked_at")
    if not checked:
        print("::error::The relay has never looked at Apple's feed.")
        return 1
    when = datetime.datetime.fromisoformat(checked.replace("Z", "+00:00"))
    minutes = (datetime.datetime.now(datetime.UTC) - when).total_seconds() / 60
    if minutes > STALE_MINUTES:
        print(f"::error::The relay last looked at Apple's feed {minutes:.0f} "
              "minutes ago; it is supposed to look every five.")
        return 1
    print(f"Relay healthy; it last looked {minutes:.0f} minute(s) ago.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
