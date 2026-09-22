"""Say when the relay can no longer start a run — once, not every quarter hour.

The relay watches Apple and asks GitHub to run this workflow the moment
something appears. If GitHub refuses — an expired dispatch token — the relay
has nowhere to say so, and the first sign is a notification that never
arrives.

Failing the run said it, but the schedule runs every fifteen minutes, so one
expired token turned into a wall of red that says the same thing ninety-six
times a day. It is reported as an issue instead: opened once while the relay
is unwell, closed by the first run that finds it healthy again.
"""
import datetime, json, os, sys, urllib.error, urllib.request

RELAY = "https://ipsw-link-catalog-feed-relay.shigelon.workers.dev/status"
# The relay looks every five minutes; six times that is not a slow minute.
STALE_MINUTES = 30
MARKER = "<!-- relay-health -->"
TITLE = "The relay cannot start the catalog workflow"


def github(path, method="GET", body=None):
    token = os.environ.get("GITHUB_TOKEN")
    repository = os.environ.get("GITHUB_REPOSITORY")
    if not token or not repository: return None
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json",
                 "User-Agent": "ipsw-link-catalog/1.0",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as failure:
        print(f"::warning::GitHub answered {failure.code} for {method} {path}")
        return None


def open_report():
    """The issue this check has already opened, if it is still open."""
    issues = github("/issues?state=open&per_page=100") or []
    return next((issue for issue in issues if MARKER in (issue.get("body") or "")), None)


def report(detail: str) -> None:
    print(f"::warning::{detail}")
    existing = open_report()
    body = (f"{MARKER}\n{detail}\n\n"
            "Real-time notifications are down until the relay's dispatch token "
            "is renewed:\n\n"
            "```\nnpx wrangler secret put GITHUB_DISPATCH_TOKEN --config feed-relay/wrangler.jsonc\n```\n\n"
            "This issue closes itself on the first run that finds the relay well.")
    if existing:
        github(f"/issues/{existing['number']}", "PATCH", {"body": body})
    else:
        github("/issues", "POST", {"title": TITLE, "body": body})


def clear() -> None:
    existing = open_report()
    if not existing: return
    github(f"/issues/{existing['number']}/comments", "POST",
           {"body": "The relay is answering again; closing."})
    github(f"/issues/{existing['number']}", "PATCH", {"state": "closed"})


def main() -> int:
    request = urllib.request.Request(RELAY, headers={"User-Agent": "ipsw-link-catalog/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            status = json.load(response)
    except Exception as failure:
        # A relay that cannot be reached from here may still be reaching
        # Apple and GitHub, so this is not a verdict on its health.
        print(f"::warning::The relay did not answer ({failure}); its health is unknown.")
        return 0

    print(json.dumps(status))
    error = status.get("last_dispatch_error")
    if error:
        report(f"GitHub is refusing the relay's request to run this workflow: `{error}`.")
        return 0

    checked = status.get("checked_at")
    if not checked:
        report("The relay has never looked at Apple's feed.")
        return 0
    when = datetime.datetime.fromisoformat(checked.replace("Z", "+00:00"))
    minutes = (datetime.datetime.now(datetime.UTC) - when).total_seconds() / 60
    if minutes > STALE_MINUTES:
        report(f"The relay last looked at Apple's feed {minutes:.0f} minutes ago; "
               "it is supposed to look every five.")
        return 0

    print(f"Relay healthy; it last looked {minutes:.0f} minute(s) ago.")
    clear()
    return 0


if __name__ == "__main__":
    sys.exit(main())
