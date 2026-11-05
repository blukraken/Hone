#!/usr/bin/env bash
# Runs build/lua's Lua on one core, for os.clock timings (MODEL-06 T1 and T4).
#
# On Windows os.clock reads wall time, so a timing is only fair when the run has a core to
# itself: start /affinity 4 pins it to logical core 2, /b keeps its output in this console,
# and the exit code comes back. Elsewhere it runs Lua directly.
#
# Usage: tests/addon/engine/pinned.sh SCRIPT [ARGS...]
#   tests/addon/engine/pinned.sh tests/addon/engine/timing.lua 300 5
#   tests/addon/engine/pinned.sh tests/addon/fixture_runner.lua --engine hone --report --stop-rule dps

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    MSYS_NO_PATHCONV=1 exec cmd /v:on /c "start /affinity 4 /b /wait build\\lua\\bin\\lua.exe $* & exit !errorlevel!"
    ;;
  *)
    exec build/lua/bin/lua "$@"
    ;;
esac
