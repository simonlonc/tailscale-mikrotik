#!/bin/sh
# Copy the license files of the Go toolchain and of every Go module compiled
# into a binary, so they can ship next to the binary.
#
# Usage: collect-go-licenses.sh <go binary (before UPX)> <output dir>
# Run inside the binary's main module (needs `go` and the module cache).
set -eu
bin=$1
out=$2
mkdir -p "$out"

copy_licenses() { # <source dir> <destination dir>
  found=
  for f in "$1"/LICENSE* "$1"/LICENCE* "$1"/COPYING* "$1"/NOTICE* "$1"/PATENTS*; do
    [ -f "$f" ] || continue
    mkdir -p "$2"
    cp "$f" "$2/"
    found=1
  done
  # some modules keep the actual license texts in a licenses/ folder
  for f in "$1"/licenses/*.txt; do
    [ -f "$f" ] || continue
    mkdir -p "$2/licenses"
    cp "$f" "$2/licenses/"
  done
  [ -n "$found" ]
}

copy_licenses "$(go env GOROOT)" "$out/go" || echo "warning: no license file in the Go toolchain" >&2

# `go version -m` lists the main module ("mod") and every dependency ("dep");
# a replaced dependency is followed by a "=>" line naming the module actually used.
go version -m "$bin" | awk '
  $1 == "mod" { print "main", $2, $3; next }
  $1 == "dep" { if (pending != "") print pending; pending = "dep " $2 " " $3; next }
  $1 == "=>"  { pending = "dep " $2 " " $3; next }
  END         { if (pending != "") print pending }
' | while read -r kind path version; do
  case $kind in
    main)
      dir=$(go list -m -f '{{.Dir}}' 2>/dev/null || pwd) ;;
    dep)
      dir=$(go mod download -json "$path@$version" 2>/dev/null | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",*$/\1/p') ;;
  esac
  if [ -z "$dir" ] || ! copy_licenses "$dir" "$out/$path"; then
    echo "warning: no license file found for $path $version" >&2
  fi
done

# FreeType-Go is used under the FreeType License, which asks for this credit
if [ -d "$out/github.com/golang/freetype" ]; then
  printf '%s\n' 'Portions of this software are copyright (c) 2010 The FreeType Project (www.freetype.org). All rights reserved.' \
    > "$out/github.com/golang/freetype/CREDIT"
fi
