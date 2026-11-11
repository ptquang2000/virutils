# tests/linux/exec-records.sh -- qemu-ga's exec records, against the bash
# driver's gexec. Not a suite of its own: sourced by tests/linux/exec.sh (the
# libvirt tree, through a stand-in virsh) and tests/mac/exec.sh (the macOS
# tree, over the agent socket), once each has sourced its exec module, pointed
# agent() at tests/mac/fake-qga.pl started with `model`, and defined VM, the
# check helpers (check, has) and IMG ($VIRUTILS_IMAGE_DIR).
#
# The cases are tests/win/exec.ps1's "qemu-ga's exec records", one for one, plus
# the two things only this driver had to change: an exit status the agent
# reports as a signal, and an agent naming an unknown pid with the generic
# "Invalid parameter 'pid'". MDE-6273 r1-4 is the case behind them: a sync's first status was
# answered by a detached run's leftover record -- exited, exit 0, no output --
# and the sync reported "all already current" for a delivery that never ran
# (docs/qga-exec-records.md).

# ctl COMMAND [ARGS_JSON] -- one of the model's test commands.
ctl() {
    local a="${2:-}"
    [[ -n "$a" ]] || a='{}'
    agent "$(jq -nc --arg x "$1" --argjson a "$a" '{execute:$x,arguments:$a}')" >/dev/null
}
reset_model() { ctl test-reset "${1:-}"; rm -rf -- "$IMG/$VM.exec"; DETACH=0; INPUT_B64=; }
add_rec() { ctl test-add-rec "$1"; }
state() { agent '{"execute":"test-state"}' | jq -c '.return'; }
recs() { state | jq -r '.recs | map(tostring) | join(" ")'; }
ledger() { ls "$IMG/$VM.exec" 2>/dev/null | sort | paste -sd' ' -; }
ledger_put() { mkdir -p "$IMG/$VM.exec" && : > "$IMG/$VM.exec/$1"; }
ERR="$(mktemp "${TMPDIR:-/tmp}/vu-err.XXXXXX")"

# The reused pid, as on win11-2: a detached run's record, finished, no output,
# exit 0, sitting ahead of the sync payload's.
reset_model '{"pid":5512,"out":"1 6400"}'
add_rec '{"pid":5512,"finished":true}'
got="$(exec_ps_text "'payload'" 2>"$ERR")"; rc=$?
check 'a reused pid still returns this call'"'"'s own output' '1 6400' "$got"
check '  with this call'"'"'s own exit code' 0 "$rc"
has '  and says the pid answered for an earlier process' 'first answered for an earlier process' "$(cat "$ERR")"
check '  and both records are consumed' '' "$(recs)"
check '  and nothing is left in the ledger' '' "$(ledger)"

# The same, behind an abandoned captured call: a record with output and a
# non-zero code, and some other call's nonce.
reset_model '{"pid":5512,"out":"mine"}'
add_rec "$(jq -nc --arg o "virutil-call $(printf '0%.0s' {1..32})"$'\n'"old output" \
    '{pid:5512,finished:true,capture:true,rc:7,out:$o}')"
got="$(exec_ps_text "'payload'" 2>/dev/null)"; rc=$?
check 'another call'"'"'s record is not taken for this one' mine "$got"
check '  nor its exit code' 0 "$rc"

# No older record, and this call's process died before printing anything: its
# own answer is the only one there is, and it must not hang the poll.
reset_model '{"pid":6000,"rc":5,"quiet":true}'
got="$(exec_ps_text "'payload'" 2>/dev/null)"; rc=$?
check 'a silent process of our own is still ours' 5 "$rc"
check '  and its (empty) output is returned' '' "$got"

# An agent that says "Invalid parameter 'pid'" (QERR_INVALID_PARAMETER) for a
# pid it has no record of, rather than "PID N does not exist". Both mean gone.
reset_model '{"pid":6002,"rc":4,"quiet":true,"oldmsg":true}'
got="$(exec_ps_text "'payload'" 2>"$ERR")"; rc=$?
check 'so does an older agent'"'"'s way of saying the pid is gone' 4 "$rc"
check '  with nothing to report about it' '' "$(cat "$ERR")"

# The nonce is stripped wherever the output goes, and only the nonce.
reset_model "$(jq -nc '{pid:6001,out:"a\r\nb\r\n"}')"
got="$(exec_ps_text "'payload'" 2>/dev/null)"
check 'the nonce never reaches the caller' $'a\nb' "$got"
reset_model '{"pid":6003,"out":"hi\n","rc":3}'
got="$(exec_sh_text 'echo hi; exit 3' 2>/dev/null)"; rc=$?
check 'an sh call carries the nonce too, and drops it' hi "$got"
check '  with the guest'"'"'s exit code' 3 "$rc"
has '  printed as the first line' "-c printf '%s\n' 'virutil-call " \
    "$(state | jq -r '.execs[0].text' | sed -n 1p)"
check '  before set -e' 'set -e' "$(state | jq -r '.execs[0].text' | sed -n 2p)"

# A process killed by a signal has no exit code; it is not a success.
reset_model '{"pid":6004,"signal":9}'
exec_ps_text "'payload'" >/dev/null 2>"$ERR"; rc=$?
check 'a guest process killed by signal 9 is 137, as a shell says' 137 "$rc"
has '  and says so' 'killed by signal 9' "$(cat "$ERR")"

# The ledger: an entry whose owner is gone is polled once and dropped with its
# record; a live owner's entry is left to it; a detached process still running
# keeps its entry for the next reap.
reset_model
add_rec '{"pid":777,"finished":true}'
add_rec '{"pid":778,"finished":true}'
add_rec '{"pid":779,"finished":false,"polls":1000}'
# 999999999 is past every pid_max; 1 is init or launchd, alive on every host
# and never us -- and another user's, so kill -0 alone would call it gone.
ledger_put 777.999999999
ledger_put 778.1
ledger_put 779.0
gexec_reap
check 'a dead owner'"'"'s record is reaped' '778.1 779.0' "$(ledger)"
check '  and only that record was consumed' '778 779' "$(recs)"

# An entry for a pid qemu-ga no longer knows is just dropped.
reset_model
ledger_put 4321.0
gexec_reap
check 'an entry for an unknown pid is dropped' '' "$(ledger)"

# Every call reaps first, so a record left behind cannot answer for it: the
# nonce check never has to step in.
reset_model '{"pid":5512,"out":"fresh"}'
add_rec '{"pid":5512,"finished":true}'
ledger_put 5512.0
got="$(exec_ps_text "'payload'" 2>"$ERR")"
check 'a ledgered record is reaped before the next call' fresh "$got"
check '  so its pid never answers for this one' '' "$(cat "$ERR")"
check '  and its entry goes with it' '' "$(ledger)"

# cmd -d stays a plain detached guest-exec (XP has no powershell for a
# launcher), and so does sh -d (Linux reuses pids slowly), so the host writes
# each down for the reaper.
reset_model '{"pid":3100}'
got="$(DETACH=1; gexec cmd.exe '["/c","shutdown"]')"
check 'cmd -d still prints the guest pid' 3100 "$got"
check '  and leaves a ledger entry for it' 3100.0 "$(ledger)"
reset_model '{"pid":3101}'
got="$(DETACH=1; exec_sh_text 'reboot')"
check 'sh -d still prints the guest pid' 3101 "$got"
check '  and leaves a ledger entry for it' 3101.0 "$(ledger)"
check '  uncaptured, with no nonce to wait for' 'false 0' \
    "$(state | jq -r '.execs[0] | "\(.capture) \(.text | test("virutil-call") | if . then 1 else 0 end)"')"

# ps -d goes through a launcher that is polled to its end: the only guest-exec
# is captured, the script is handed over on stdin, the pid printed is the one
# the launcher started, and no record or entry is left.
reset_model '{"pid":6100,"out":"7777"}'
got="$(DETACH=1; exec_ps_text "'long job'" 2>/dev/null)"
check 'ps -d prints the started process'"'"'s pid' 7777 "$got"
check '  through one guest-exec' 1 "$(state | jq '.execs | length')"
check '  which is captured, so it gets polled' true "$(state | jq -r '.execs[0].capture')"
handed="$(state | jq -r '.execs[0].input' | tr -d '[:space:]' | base64 -d | iconv -f UTF-16LE -t UTF-8)"
has '  the script reaches the launcher on stdin' "'long job'" "$handed"
has '  and the launcher starts it shell-executed' 'UseShellExecute = $true' "$(state | jq -r '.execs[0].text')"
check '  no record is left in qemu-ga' '' "$(recs)"
check '  and nothing in the ledger' '' "$(ledger)"
reset_model
why="$( (DETACH=1; INPUT_B64=eA==; exec_ps_text "'x'") 2>&1 >/dev/null)"
has 'ps -d with stdin is refused, not dropped' 'cannot hand stdin' "$why"
check '  before anything reaches the guest' 0 "$(state | jq '.execs | length')"

rm -f -- "$ERR"
