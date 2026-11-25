#!/bin/bash
# Launches a built Tellurion in the background and watches it sit idle: it has to stay up,
# stay quiet and stay the same size. Used by release.sh on the app about to ship and by CI
# on the macOS versions the build machine doesn't run.
#
#   launch-test.sh [--window] <app> <empty folder for its files> [seconds, default 60]
#
# Started the quiet way (`open -g`), the app takes no focus, and so opens no window either:
# that only shows it can start and sit there. With --window its program is started directly,
# which opens its first window, behind whatever is in front and without taking the keyboard:
# then the sidebar, the terminal and the app's own health monitor are all running, in "/", a
# folder outside any repository (the case that once sent a lookup past the top of the disk
# and grew the app until the Mac ran out of memory). Its boards, prompts and hooks go to the
# folder given.
# Exit: 0 fine, 1 the app failed the test (said why), 2 the test couldn't run.
set -uo pipefail

WINDOW=0
if [[ ${1:-} == --window ]]; then
  WINDOW=1
  shift
fi
APP=${1:-}
TEST_HOME=${2:-}
SECONDS_TO_RUN=${3:-60}
# The first stretch is the app starting up: reading its files, drawing its first window.
WARM_UP=20
# Idle, it uses a fraction of a percent of one core; this much is something spinning.
MOST_CPU=5
# And it holds what it holds: this much growth in under a minute is something collecting.
MOST_GROWTH_MB=50

[[ -d $APP && -x $APP/Contents/MacOS/ghostty ]] || { echo "usage: launch-test.sh [--window] <app> <empty folder> [seconds]" >&2; exit 2; }
[[ -n $TEST_HOME ]] || { echo "launch-test.sh: no folder for the app's files" >&2; exit 2; }
[[ $SECONDS_TO_RUN =~ ^[0-9]+$ ]] && (( SECONDS_TO_RUN > WARM_UP + 10 )) || { echo "launch-test.sh: at least $((WARM_UP + 11)) seconds" >&2; exit 2; }
mkdir -p "$TEST_HOME" || { echo "launch-test.sh: can't make $TEST_HOME" >&2; exit 2; }
BINARY=$APP/Contents/MacOS/ghostty

crash_reports() {
  local listing
  listing=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null) || true
  grep -ci ghostty <<<"$listing" || true
}
# The app's processor time so far, in hundredths of a second ("0:01.23" or "1:02:03.45").
cpu_time() {
  ps -o time= -p "$1" 2>/dev/null | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%d", s * 100 }'
}
memory_mb() {
  ps -o rss= -p "$1" 2>/dev/null | awk '{ printf "%d", $1 / 1024 }'
}
stop() {
  [[ -n ${PID:-} ]] && kill "$PID" 2>/dev/null
  sleep 1
  [[ -n ${PID:-} ]] && kill -9 "$PID" 2>/dev/null
  return 0
}
failed() {
  echo "$1"
  stop
  exit 1
}

CRASHES_BEFORE=$(crash_reports)
if (( WINDOW )); then
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin TELLURION_TEST_HOME="$TEST_HOME" \
    "$BINARY" --window-save-state=never --working-directory=/ >/dev/null 2>&1 &
  # Not this shell's job any more, so stopping it later isn't announced on the output.
  disown
else
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin TELLURION_TEST_HOME="$TEST_HOME" \
    /usr/bin/open -gna "$APP" --args --window-save-state=never --working-directory=/ \
    || { echo "launch-test.sh: couldn't open $APP" >&2; exit 2; }
fi

sleep "$WARM_UP"
PID=$(pgrep -f "^$BINARY" | head -n 1 || true)
[[ -n $PID ]] || failed "the app quit or crashed on launch"
# The app's health monitor leaves a note once its first window is up.
if (( WINDOW )) && [[ ! -f $TEST_HOME/.ghostty-extreme/health/running.json ]]; then
  failed "the app started but never opened its window"
fi
CPU_BEFORE=$(cpu_time "$PID")
MEMORY_BEFORE=$(memory_mb "$PID")
[[ -n $CPU_BEFORE && -n $MEMORY_BEFORE ]] || failed "the app quit while it was being measured"

WATCHED=$((SECONDS_TO_RUN - WARM_UP))
sleep "$WATCHED"
kill -0 "$PID" 2>/dev/null || { PID=""; failed "the app quit or crashed after $WARM_UP seconds"; }
CPU_AFTER=$(cpu_time "$PID")
MEMORY_AFTER=$(memory_mb "$PID")
[[ -n $CPU_AFTER && -n $MEMORY_AFTER ]] || failed "the app quit while it was being measured"

# Hundredths of a second used, over seconds watched, is already a percentage of one core.
CPU=$(( (CPU_AFTER - CPU_BEFORE) / WATCHED ))
GROWTH=$(( MEMORY_AFTER - MEMORY_BEFORE ))
# What the app noticed about itself: a report means a freeze or memory out of bounds.
REPORTS=$(ls "$TEST_HOME/.ghostty-extreme/health" 2>/dev/null | grep -c '^report-' || true)
REASON=""
if (( REPORTS > 0 )); then
  NEWEST=$(ls "$TEST_HOME/.ghostty-extreme/health" | grep '^report-' | sort | tail -n 1)
  REASON=$(sed -n 's/.*"reason" : "\(.*\)".*/\1/p' "$TEST_HOME/.ghostty-extreme/health/$NEWEST")
fi
stop
PID=""

[[ $(crash_reports) == "$CRASHES_BEFORE" ]] || { echo "a crash report appeared"; exit 1; }
(( REPORTS == 0 )) || { echo "the app reported a problem with itself: ${REASON:-see its health report}"; exit 1; }
(( CPU <= MOST_CPU )) || { echo "idle, the app used ${CPU}% of a core (the most allowed is ${MOST_CPU}%)"; exit 1; }
(( GROWTH <= MOST_GROWTH_MB )) || { echo "idle, the app grew by ${GROWTH} MB in ${WATCHED} s (the most allowed is ${MOST_GROWTH_MB})"; exit 1; }
WITH="without a window"
(( WINDOW )) && WITH="with a window open"
echo "stayed up for ${SECONDS_TO_RUN} s ${WITH}: idle CPU ${CPU}%, ${MEMORY_AFTER} MB (${GROWTH} MB of growth), no crash, freeze or memory report"
