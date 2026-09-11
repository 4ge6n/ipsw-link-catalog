"""Publish a small, safe status document even when a catalog run fails."""
from __future__ import annotations
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).parent.parent

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", choices=("success", "failure"), required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--failed-step", default=None)
    args = parser.parse_args()
    path = ROOT / "api" / "status.json"
    previous = json.loads(path.read_text()) if path.exists() else {}
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    document = {
        "schema_version": 1,
        "state": args.state,
        "last_attempt_at": now,
        "last_success_at": now if args.state == "success" else previous.get("last_success_at"),
        "run_url": args.run_url,
        "failed_step": args.failed_step if args.state == "failure" else None,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2) + "\n")

if __name__ == "__main__":
    main()
