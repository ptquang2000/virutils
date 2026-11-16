# ui, Linux guest. Sent by `virutil ui run` and by sync's >pre-ui/>post-ui
# rules: start one process on a graphical session's desktop and return.
#
#   @SESSION@  the logind session id; '' = the first active graphical one
#   @AS@       'user'   -- as the user that session belongs to
#              'system' -- as root, on that session's display
#   @ARGV@     the argv, joined with U+001F
#   @CMDLINE@  a whole command line, run by /bin/sh; wins over @ARGV@
#
# The agent runs this as root with no display, which is session 0 over again:
# what it starts is seen by nobody. A graphical session here is a logind
# session of class user and type wayland or x11 -- the greeter's is class
# greeter, so a guest at its login screen has none, and that is exit
# @@RC_UI_NO_USER@@ exactly as on Windows.
#
# The process is started by the user's own systemd, as a transient unit, and
# not forked from here: that manager holds the environment the session
# published when it began (WAYLAND_DISPLAY, DISPLAY, XAUTHORITY, the bus), so
# nothing has to be guessed about which display server it runs or where its
# socket is, and the process lands under the user's slice rather than inside
# the agent's own service, where a restart of the agent would take it away. It
# is what the desktop does with an application it launches.
#
# 'system' cannot borrow that manager, so it reads the same environment out of
# it and hands root the four names that address the display.
#
# Type=exec so a program that cannot be started fails here, with systemd's
# reason, rather than as a unit that started and died; an older systemd has no
# such type and is given the default.
#
# Prints: "started PID <pid> in session <n> as <user>". The process is not
# waited on; one that is gone before its pid is read (--collect has already
# dropped the unit, and MainPID reads 0) is said to have exited instead.
want=@SESSION@
as=@AS@
argv=@ARGV@
cmdline=@CMDLINE@
sid= user=
for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  [ -z "$want" ] || [ "$want" = "$s" ] || continue
  p=$(loginctl show-session "$s" -p Class -p Type -p State -p Name 2>/dev/null) || continue
  case $p in *Class=user*) ;; *) continue ;; esac
  case $p in *Type=wayland*|*Type=x11*) ;; *) continue ;; esac
  [ -n "$want" ] || case $p in *State=active*) ;; *) continue ;; esac
  sid=$s
  user=$(printf '%s\n' "$p" | sed -n 's/^Name=//p')
  break
done
if [ -z "$sid" ] || [ -z "$user" ]; then
  if [ -n "$want" ]; then echo "session $want is not a user's graphical session" >&2
  else echo "no user is logged on to a graphical session" >&2; fi
  exit @@RC_UI_NO_USER@@
fi
uid=$(id -u "$user")
rt=/run/user/$uid
asuser() { runuser -u "$user" -- env XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" "$@"; }
unit=virutil-ui-$(date +%s)-$$
type=exec
systemd-run --help 2>/dev/null | grep -q -- --collect || { echo "systemd-run here is too old to start a transient unit with" >&2; exit 1; }
[ "$(systemctl --version | awk 'NR==1{print $2}')" -ge 240 ] 2>/dev/null || type=simple
if [ -n "$cmdline" ]; then set -- /bin/sh -c "$cmdline"
else oldifs=$IFS; IFS=$(printf '\037'); set -- $argv; IFS=$oldifs; fi
if [ "$as" = system ]; then
  set -- --collect --quiet --unit="$unit" -p Type=$type -- "$@"
  for kv in $(asuser systemctl --user show-environment | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY)='); do
    set -- -E "$kv" "$@"
  done
  systemd-run -E XDG_RUNTIME_DIR="$rt" "$@" || exit 1
  pid=$(systemctl show -p MainPID --value "$unit")
  who=root
else
  asuser systemd-run --user --collect --quiet --unit="$unit" -p Type=$type -- "$@" || exit 1
  pid=$(asuser systemctl --user show -p MainPID --value "$unit")
  who=$user
fi
case $pid in
  ''|0) echo "started in session $sid as $who; it has already exited" ;;
  *) echo "started PID $pid in session $sid as $who" ;;
esac
