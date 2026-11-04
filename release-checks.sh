#!/bin/bash
# Checks release.sh relies on, apart from it so test_release_checks.py can try them on
# files made to pass and made to fail.
#   release-checks.sh ghostty-version <build.zig.zon>       prints the Ghostty version
#   release-checks.sh test-switches <binary> <source folder> prints test switches in the binary
# Exit: 0 clean, 1 the binary has test switches, 2 the check itself couldn't run. Anything
# but 0 has to stop a release: a check that can't run must not look like one that passed.
set -uo pipefail
export LC_ALL=C

# Swift keeps a string of 15 bytes or fewer inside the instructions, where grep can't see it.
SHORTEST_VISIBLE=16
# A hooks build has far more. Fewer means the names moved and this search no longer finds them.
FEWEST_NAMES=20

problem() { echo "$1" >&2; exit 2; }

ghostty_version() {
  [[ -r $1 && -f $1 ]] || problem "can't read $1"
  # Four spaces: the package's own version, not one nested in a dependency.
  local version
  version=$(sed -n -E 's/^    \.version = "([0-9]+\.[0-9]+\.[0-9]+[^"]*)",?[[:space:]]*$/\1/p' "$1" | head -1)
  [[ -n $version ]] || problem "no version in $1"
  echo "$version"
}

test_switches() {
  local binary=$1 sources=$2 names found status
  [[ -r $binary && -f $binary && -s $binary ]] || problem "can't read the binary $binary"
  [[ -d $sources ]] || problem "no source folder $sources"
  # Every switch is read through TestHooks.value or .flag, so the source lists them all and
  # renaming them can't leave this search looking for the old names.
  names=$(grep -rhoE '(value|flag)\("[A-Z][A-Z0-9_]*"\)' --include='*.swift' "$sources" \
    | sed -E 's/.*"(.*)".*/\1/' | sort -u | awk -v n=$SHORTEST_VISIBLE 'length($0) >= n')
  (( $(printf '%s' "$names" | grep -c '') >= FEWEST_NAMES )) \
    || problem "found too few test switch names in $sources"
  found=$(grep -a -o -F -f <(printf '%s\n' "$names") "$binary")
  status=$?
  (( status <= 1 )) || problem "couldn't search $binary"
  [[ -z $found ]] && return 0
  printf '%s\n' "$found" | sort -u
  return 1
}

case "${1:-}:$#" in
  ghostty-version:2) ghostty_version "$2" ;;
  test-switches:3) test_switches "$2" "$3" ;;
  *) problem "usage: release-checks.sh ghostty-version <file> | test-switches <binary> <source folder>" ;;
esac
