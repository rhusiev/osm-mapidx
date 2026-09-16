#!/usr/bin/env bash
# Turn the synthetic .osm.pbf into a POI-only .obf that OsmAnd loads alongside
# its official maps. Argument is the region name used by mapidx.cli.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
exec .venv/bin/python -m mapidx.cli obf --region "${1:-lviv}"
