#!/bin/zsh -l
set -uo pipefail

project_root="${0:A:h}"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

printf '\nScholia — install or update\n\n'
printf 'Building the latest changes in %s\n' "$project_root"
printf 'Scholia will reopen from Applications when the update is ready.\n\n'

update_exit_code=0
if /bin/zsh "$project_root/scripts/install-macos-app.sh" --launch "$@"; then
  printf '\nScholia is ready.\n'
else
  update_exit_code=$?
  printf '\nThe update did not finish. See the error above.\n' >&2
fi

if [[ -t 0 ]] && read -r '?Press Enter to close this window.'; then
  if [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]]; then
    update_tty="$(tty)"
    # Capture this window while its TTY is still attached. The helper waits
    # outside this terminal session until the launcher has exited.
    terminal_closer="$project_root/scripts/close-updater-terminal.applescript"
    /usr/bin/osascript "$terminal_closer" "$update_tty" "$terminal_closer"
  fi
fi
exit "$update_exit_code"
