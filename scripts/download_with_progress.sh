#!/bin/bash
# Run the latest iPhone/iPad/iPod downloader with visible curl progress bars.
# Six downloads are run concurrently; progress-bar output can interleave while
# several Apple CDN transfers are active.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export CHANNEL="${CHANNEL:-release}"
export SHOW_PROGRESS=1
export MAX_CONCURRENT=6

exec bash "$SCRIPT_DIR/download_latest.sh"
