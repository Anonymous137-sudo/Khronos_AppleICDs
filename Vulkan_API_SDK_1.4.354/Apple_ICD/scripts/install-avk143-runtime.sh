#!/bin/sh
set -eu

usage() {
    printf '%s\n' "usage: $0 [--prefix <runtime-prefix>]"
    exit 2
}

prefix=${HOME}/.local
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || usage
            prefix=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/stage-avk143-runtime.sh" --prefix "$prefix"
