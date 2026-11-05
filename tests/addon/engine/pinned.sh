#!/usr/bin/env bash
# Runs build/lua's Lua on one core, for os.clock timings (MODEL-06 T4, MODEL-06b T1 and T3).
#
# On Windows os.clock reads wall time, so a timing is only fair when the run has a core to
# itself: start /affinity 4 pins it to logical core 2, /b keeps its output in this console,
# and the exit code comes back. Elsewhere it runs Lua directly.
#
# Usage: tests/addon/engine/pinned.sh [build/lua/bin/lua.exe] SCRIPT [ARGS...]
#   tests/addon/engine/pinned.sh tests/addon/engine/timing.lua 300 5
#   tests/addon/engine/pinned.sh build/lua/bin/lua.exe tests/addon/fixture_runner.lua --engine hone --report --staged
# A leading interpreter path is optional; the run always uses build/lua's Lua.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

case "${1:-}" in
  *lua.exe|*/lua) shift ;;
esac

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    MSYS_NO_PATHCONV=1 exec cmd /v:on /c "start /affinity 4 /b /wait build\\lua\\bin\\lua.exe $* & exit !errorlevel!"
    ;;
  *)
    exec build/lua/bin/lua "$@"
    ;;
esac
