#!/bin/bash
# Checks release.sh relies on, apart from it so test_release_checks.py can try them on
# files made to pass and made to fail.
#   release-checks.sh ghostty-version <build.zig.zon>       prints the Ghostty version
#   release-checks.sh test-switches <binary> <source folder> prints test switches in the binary
#   release-checks.sh secrets <diff file>                    prints where the diff adds a key or token
#   release-checks.sh mentions <diff file> <text>            prints where the diff adds that text
#   release-checks.sh notary-key <env file>                  prints the notarization API key it names
#   release-checks.sh notary-advice <notarytool output> <profile> <team>  prints what to do about a refused login
#   release-checks.sh symbols <binary> <dSYM>                do the debug symbols belong to the binary?
# Exit: 0 clean, 1 found (test switches, keys, the text; no API key named; symbols of another
# build), 2 the check itself couldn't run.
# Anything but 0 has to stop a release: a check that can't run must not look like one that passed.
#
# Nothing here reads a pipe with `grep -q` or `head`: a reader that stops at the first match
# kills the writer, and under pipefail the whole check then counts as "nothing found".
set -uo pipefail
export LC_ALL=C

# Swift keeps a string of 15 bytes or fewer inside the instructions, where grep can't see it.
SHORTEST_VISIBLE=16
# A hooks build has far more. Fewer means the names moved and this search no longer finds them.
FEWEST_NAMES=20

# What a key or token looks like: API keys, GitHub tokens, AWS keys, a private key, Slack tokens.
SECRETS='(sk-(ant|proj)-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[A-Za-z0-9-]{10,})'

problem() { echo "$1" >&2; exit 2; }

ghostty_version() {
  [[ -r $1 && -f $1 ]] || problem "can't read $1"
  # Four spaces: the package's own version, not one nested in a dependency.
  local version
  version=$(sed -n -E 's/^    \.version = "([0-9]+\.[0-9]+\.[0-9]+[^"]*)",?[[:space:]]*$/\1/p' "$1")
  version=${version%%$'\n'*}
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

# Every line a diff adds, as "file:line:text". Counted from the hunk headers, so an added line
# that itself starts with "++ " or "@@" isn't taken for a header.
added_lines() {
  [[ -r $1 && -f $1 ]] || problem "can't read the diff $1"
  awk '
    function count(range,   parts) { return split(range, parts, ",") > 1 ? parts[2] + 0 : 1 }
    old > 0 || new > 0 {
      kind = substr($0, 1, 1)
      if (kind == "+") { print file ":" line ":" substr($0, 2); line++; new-- }
      else if (kind == "-") old--
      else if (kind != "\\") { old--; new--; line++ }
      next
    }
    /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
    /^@@ / { old = count($2); new = count($3); line = substr($3, 2) + 0 }
  ' "$1" || problem "couldn't read the diff $1"
}

# Where the added lines match, or nothing. grep reads a string here, not a pipe.
matches() {  # matches <grep option> <pattern> <added lines>
  local found status
  [[ -n $3 ]] || return 0
  found=$(grep "$1" -e "$2" <<<"$3")
  status=$?
  (( status <= 1 )) || problem "couldn't search the changes"
  printf '%s' "$found"
}

added_secrets() {
  local lines found
  lines=$(added_lines "$1") || exit 2
  found=$(matches -E "$SECRETS" "$lines") || exit 2
  [[ -z $found ]] && return 0
  # Where it is, never what it is: this goes to a terminal, and maybe into a log.
  sed -E "s/$SECRETS/[hidden]/g" <<<"$found" | cut -c1-160
  return 1
}

added_mentions() {
  local lines found
  [[ -n $2 ]] || problem "no text to look for"
  lines=$(added_lines "$1") || exit 2
  found=$(matches -F "$2" "$lines") || exit 2
  [[ -z $found ]] && return 0
  cut -c1-160 <<<"$found"
  return 1
}

# The notarization login as an App Store Connect API key, named in a file outside the repo:
#   NOTARY_KEY=<path to AuthKey_….p8>   NOTARY_KEY_ID=…   NOTARY_ISSUER=…
# Read as plain name=value lines, never run. Prints the three values, one per line.
# 1: no such file, or it names none of them, so the keychain profile is the login.
# 2: half filled in, or the key file is gone. A release must stop there, not quietly fall
# back to a login the maintainer thought they had replaced.
notary_key() {
  local file=$1 key="" id="" issuer="" name value
  [[ -e $file ]] || return 1
  [[ -r $file && -f $file ]] || problem "can't read $file"
  while IFS='=' read -r name value || [[ -n $name ]]; do
    value=${value%$'\r'}
    value=${value#\"}
    value=${value%\"}
    case $name in
      NOTARY_KEY) key=${value/#\~/$HOME} ;;
      NOTARY_KEY_ID) id=$value ;;
      NOTARY_ISSUER) issuer=$value ;;
    esac
  done < "$file"
  [[ -z $key$id$issuer ]] && return 1
  [[ -n $key && -n $id && -n $issuer ]] || problem "$file needs all of NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER"
  [[ -r $key && -f $key ]] || problem "the notarization key $key (named in $file) can't be read"
  printf '%s\n%s\n%s\n' "$key" "$id" "$issuer"
}

# notarytool's own words for a refused login, turned into what to do next.
notary_advice() {
  local file=$1 profile=$2 team=$3 text
  [[ -r $file && -f $file ]] || problem "can't read $file"
  text=$(<"$file")
  case $text in
    *agreement*)
      echo "Apple wants an agreement accepted first. Sign in at developer.apple.com/account (and appstoreconnect.apple.com, under Business), accept it, and try again in a few minutes." ;;
    *"No Keychain password item"*)
      echo "The notarization login \"$profile\" is gone from the keychain. Save it again in a terminal: xcrun notarytool store-credentials $profile --apple-id <Apple ID> --team-id $team" ;;
    *"HTTP status code: 401"*|*"nvalid credentials"*)
      echo "Apple refused the login itself. An app-specific password may have been revoked, or the API key removed: create a new one and save it again." ;;
    *)
      text=$(awk 'NF {line = $0} END {print line}' "$file")
      echo "notarytool said: ${text:-nothing}" ;;
  esac
}

# The app is stripped before it ships, so the debug symbols are kept apart, and they only
# read a user's crash or hang report if they come from the very same build: same UUIDs.
symbols_match() {
  local binary=$1 dsym=$2 of_binary of_symbols
  [[ -r $binary && -f $binary ]] || problem "can't read the binary $binary"
  [[ -d $dsym ]] || problem "no debug symbols at $dsym"
  of_binary=$(dwarfdump --uuid "$binary" 2>/dev/null | awk '{print $2, $3}' | sort) || problem "couldn't read the binary's UUID"
  of_symbols=$(dwarfdump --uuid "$dsym" 2>/dev/null | awk '{print $2, $3}' | sort) || problem "couldn't read the symbols' UUID"
  [[ -n $of_binary ]] || problem "$binary has no UUID"
  [[ -n $of_symbols ]] || problem "$dsym holds no debug symbols"
  [[ $of_binary == "$of_symbols" ]] && return 0
  echo "binary:  ${of_binary//$'\n'/, }"
  echo "symbols: ${of_symbols//$'\n'/, }"
  return 1
}

case "${1:-}:$#" in
  ghostty-version:2) ghostty_version "$2" ;;
  test-switches:3) test_switches "$2" "$3" ;;
  secrets:2) added_secrets "$2" ;;
  mentions:3) added_mentions "$2" "$3" ;;
  notary-key:2) notary_key "$2" ;;
  notary-advice:4) notary_advice "$2" "$3" "$4" ;;
  symbols:3) symbols_match "$2" "$3" ;;
  *) problem "usage: release-checks.sh ghostty-version <file> | test-switches <binary> <source folder> | secrets <diff file> | mentions <diff file> <text> | notary-key <env file> | notary-advice <output> <profile> <team> | symbols <binary> <dSYM>" ;;
esac
