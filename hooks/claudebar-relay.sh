#!/bin/bash
# Relays a Claude Code hook payload (JSON on stdin) to the ClaudeBar app's
# unix socket. Exits 0 no matter what — a missing or stopped ClaudeBar
# should never break your Claude Code session.
#
# Fast path: ClaudeBar hangs up as soon as it has the whole payload, so
# this returns in milliseconds. -w 1 is only a backstop if the app is wedged.
# stdout goes to /dev/null on purpose: for some hook events Claude Code
# feeds a hook's stdout back to the model as context.
SOCKET="$HOME/.claudebar/claudebar.sock"

if [ -S "$SOCKET" ]; then
  /usr/bin/nc -U -w 1 "$SOCKET" >/dev/null 2>&1
else
  cat > /dev/null
fi

exit 0
