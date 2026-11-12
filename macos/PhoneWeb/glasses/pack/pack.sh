#!/bin/sh
# Builds the glasses app as a package for the glasses' menu (Even Hub), made for one Mac:
# the address Tellurion's Phone window shows, e.g. https://my-mac.my-tailnet.ts.net
#
#   pack.sh <address> [version] [output.ehpk]
#   pack.sh --files <folder> <address> [version]     only write the files, don't pack
#
# The package holds the web files, config.js with that address, and app.json. Nothing
# secret goes in: the glasses pair with the Mac afterwards. Everything is written to a
# temporary folder (or the one you name), never next to this script.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
web=$(dirname "$here")

files_only=""
if [ "${1:-}" = "--files" ]; then
  files_only=${2:?"--files needs a folder"}
  shift 2
fi

origin=${1:-}
version=${2:-1.0.0}
output=${3:-}

origin=${origin%/}
if ! printf '%s' "$origin" | grep -Eq '^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$'; then
  echo "Give your Mac's address as Tellurion's Phone window shows it, like https://my-mac.my-tailnet.ts.net" >&2
  exit 1
fi
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "The version has to look like 1.0.0 (a higher one for every upload)." >&2
  exit 1
fi

if [ -n "$files_only" ]; then
  work=$files_only
  mkdir -p "$work"
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/tellurion-glasses.XXXXXX")
fi
build="$work/app"
rm -rf "$build"
mkdir -p "$build/vendor"

# The app's own files; not its tests, and not this helper.
cp "$web"/index.html "$web"/app.css "$web"/*.js "$build/"
cp -R "$web/vendor/." "$build/vendor/"
printf '// Written by pack.sh: the Mac this package talks to.\nexport const TELLURION_ORIGIN = "%s";\n' "$origin" > "$build/config.js"
sed -e "s|__ORIGIN__|$origin|" -e "s|__VERSION__|$version|" "$here/app.json" > "$work/app.json"

if [ -n "$files_only" ]; then
  echo "$work"
  exit 0
fi

[ -n "$output" ] || output="$work/Tellurion.ehpk"
# Even's own packer. It checks the manifest and needs no account.
npx --yes @evenrealities/evenhub-cli pack "$work/app.json" "$build" -o "$output"
echo
echo "Packed for $origin: $output"
echo "Next, with your Even Hub account: evenhub login, then evenhub create (first time) or"
echo "evenhub upload \"$output\" -m \"...\", then evenhub promote $version --to beta."
