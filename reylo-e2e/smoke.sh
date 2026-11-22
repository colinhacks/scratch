#!/usr/bin/env bash
# smoke.sh <channel> <reylo>: the reylo a channel installed reports the expected version and starts
# a SQLite project's migrations.
set -u
channel="$1"
bin="$2"
want="reylo ${REYLO_VERSION:-0.8.2}"
dir="$(mktemp -d)"
fail() { echo "FAIL [channel $channel] $*"; exit 1; }
got="$("$bin" --version 2>&1)" || fail "--version exited $?: $got"
[ "$got" = "$want" ] || fail "--version printed \"$got\", not \"$want\""
cd "$dir" || exit 1
printf 'DATABASE_URL=sqlite:./app.db\n' > .env
out="$("$bin" migrate init 2>&1)" || fail "migrate init: $out"
printf 'create table notes (id integer primary key, body text not null) strict;\n' > reylo/schema.sql
out="$("$bin" migrate new first 2>&1)" || fail "migrate new: $out"
out="$("$bin" migrate dev 2>&1)" || fail "migrate dev: $out"
out="$("$bin" migrate status 2>&1)" || fail "migrate status: $out"
echo "PASS [channel $channel] $got: init, new, dev and status on SQLite ($bin)"
