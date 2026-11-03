-- Close only the updater's dedicated window, even if another window is focused.
on run arguments
  if item 1 of arguments is not "--close-window" then
    set updaterTTY to item 1 of arguments
    set helperPath to item 2 of arguments
    set updaterWindowID to missing value
    tell application "Terminal"
      repeat with terminalWindow in windows
        if (count tabs of terminalWindow) is 1 then
          if tty of selected tab of terminalWindow is updaterTTY then
            set updaterWindowID to id of terminalWindow
            exit repeat
          end if
        end if
      end repeat
    end tell
    if updaterWindowID is missing value then return
    -- Standard Additions starts this helper outside the updater's terminal
    -- session, so it survives shell exit and does not keep the window busy.
    do shell script "/usr/bin/nohup /usr/bin/osascript " & quoted form of helperPath & " --close-window " & updaterWindowID & " </dev/null >/dev/null 2>&1 &"
    return
  end if

  set updaterWindowID to (item 2 of arguments) as integer
  repeat 100 times
    tell application "Terminal"
      -- The user's profile may have already closed it when the shell exited.
      if not (exists window id updaterWindowID) then return
      set terminalWindow to window id updaterWindowID
      -- Never close other tabs that the user has added to this window.
      if (count tabs of terminalWindow) is not 1 then return
      if not busy of selected tab of terminalWindow then
        close terminalWindow saving no
        return
      end if
    end tell
    delay 0.1
  end repeat
end run
