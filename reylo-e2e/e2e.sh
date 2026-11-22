#!/usr/bin/env bash
# A new user's walk through Reylo Migrate, as the docs at reylo.dev/migrate/docs describe it, on one
# dialect. Every step is checked; a failed step is reported and the walk goes on, and the script
# exits 1 if any step failed.
#
#   e2e.sh <sqlite|postgres|mysql> <work dir>
#
# reylo must be on PATH. For postgres and mysql, E2E_SERVER names a server URL whose account may
# create databases (postgres://postgres@127.0.0.1:5432, mysql://root@127.0.0.1:3306).
# E2E_NODE=1 also runs the migrate() API from reylo's npm package (needs node 24 and npm).
set -u

dialect="$1"
work="$2"
version="${REYLO_VERSION:-0.8.2}"
failures=0
out=""
step_no=0

log() { printf '%s\n' "$*"; }
run() {
  # run <expected exit: 0|nonzero|any> <name> <command...>; the output is kept in $out
  local want="$1" name="$2"
  shift 2
  step_no=$((step_no + 1))
  out="$("$@" 2>&1)"
  local code=$?
  local ok=1
  case "$want" in
    0) [ "$code" -eq 0 ] || ok=0 ;;
    nonzero) [ "$code" -ne 0 ] || ok=0 ;;
  esac
  if [ "$ok" -eq 1 ]; then
    log "PASS [$dialect] $step_no $name (exit $code)"
  else
    failures=$((failures + 1))
    log "FAIL [$dialect] $step_no $name: wanted exit $want, got $code"
    log "  \$ $*"
    printf '%s\n' "$out" | sed 's/^/  | /'
  fi
}
expect() {
  # expect <name> <fixed string>: the last output holds it
  if printf '%s' "$out" | grep -qF -- "$2"; then
    log "PASS [$dialect]   $1"
  else
    failures=$((failures + 1))
    log "FAIL [$dialect]   $1: output lacks \"$2\""
    printf '%s\n' "$out" | sed 's/^/  | /'
  fi
}
show() { printf '%s\n' "$out" | sed 's/^/  > /'; }

# The schema, by what has happened to it so far: published (a column added), nobody (body dropped),
# headline (title renamed), hotfix (a column added by hand on production).
schema() {
  local published="${1:-}" nobody="${2:-}" headline="${3:-}" hotfix="${4:-}"
  local title=title body=",
  body text"
  [ -n "$nobody" ] && body=""
  [ -n "$headline" ] && title=headline
  case "$dialect" in
    sqlite)
      cat <<EOF
create table users (
  id integer primary key,
  email text not null unique,
  name text not null${hotfix:+,
  hotfix integer}
) strict;

create table posts (
  id integer primary key,
  user_id integer not null references users (id) on delete cascade,
  $title text not null$body${published:+,
  published_at text},
  created_at text not null default (datetime('now'))
) strict;

create index posts_user on posts (user_id);

create view post_titles as
  select p.id, p.$title as title, u.name as author from posts p join users u on u.id = p.user_id;

create trigger users_lower_email after insert on users
begin
  update users set email = lower(new.email) where id = new.id;
end;
EOF
      ;;
    postgres)
      cat <<EOF
create type status as enum ('draft', 'live');

create table users (
  id bigint generated always as identity primary key,
  email text not null unique,
  name text not null,
  updated_at timestamptz not null default now()${hotfix:+,
  hotfix bigint}
);

create table posts (
  id bigint generated always as identity primary key,
  user_id bigint not null references users (id) on delete cascade,
  $title text not null$body${published:+,
  published_at timestamptz},
  status status not null default 'draft',
  created_at timestamptz not null default now()
);

create index posts_user on posts (user_id);
create index posts_live on posts (created_at) where status = 'live';

create view post_titles as
  select p.id, p.$title as title, u.name as author from posts p join users u on u.id = p.user_id;

create function touch() returns trigger language plpgsql as \$\$
begin
  new.updated_at := now();
  return new;
end \$\$;

create trigger users_touch before update on users for each row execute function touch();

comment on table posts is 'What users write';
EOF
      ;;
    mysql)
      cat <<EOF
create table users (
  id bigint not null auto_increment primary key,
  email varchar(255) not null unique,
  name varchar(100) not null${hotfix:+,
  hotfix bigint}
);

create table posts (
  id bigint not null auto_increment primary key,
  user_id bigint not null,
  $title varchar(200) not null$body${published:+,
  published_at datetime},
  status enum('draft', 'live') not null default 'draft',
  created_at datetime not null default current_timestamp,
  index posts_user (user_id),
  constraint posts_user_fk foreign key (user_id) references users (id) on delete cascade
);

create view post_titles as
  select p.id, p.$title as title, u.name as author from posts p join users u on u.id = p.user_id;

create trigger users_lower_email before insert on users for each row set new.email = lower(new.email);
EOF
      ;;
  esac
}

seed() {
  cat <<EOF
insert into users (email, name) values ('ADA@example.com', 'Ada');
insert into posts (user_id, title, body) values (1, 'Hello', 'First post');
EOF
}

rm -rf "$work" && mkdir -p "$work" && cd "$work" || exit 1
log "== $dialect in $work, $(reylo --version) on $(uname -s 2>/dev/null) $(uname -m 2>/dev/null)"

case "$dialect" in
  sqlite)
    dev="sqlite:./dev.db"
    prod="sqlite:./prod.db"
    ;;
  postgres | mysql)
    server="${E2E_SERVER:?E2E_SERVER names the server}"
    suffix="$(date +%s)$$"
    if [ "$dialect" = postgres ]; then admin="$server/postgres"; else admin="$server"; fi
    run 0 "create the dev and prod databases" reylo run --url "$admin" "create database e2e_dev_$suffix" "create database e2e_prod_$suffix"
    dev="$server/e2e_dev_$suffix"
    prod="$server/e2e_prod_$suffix"
    ;;
esac

# Start, as the docs' Basic usage does: a .env naming the dev database.
printf 'DATABASE_URL=%s\n' "$dev" > .env
run 0 "migrate init on an empty database" reylo migrate init
expect "init says the database is empty" "for an empty database"
[ -f reylo/schema.sql ] && [ -f reylo/reylo.lock ] && log "PASS [$dialect]   init wrote schema.sql and reylo.lock" || { failures=$((failures + 1)); log "FAIL [$dialect]   init wrote no schema.sql or reylo.lock"; ls -la reylo; }

schema > reylo/schema.sql
run 0 "migrate new init (the first migration)" reylo migrate new init
expect "new wrote a file" "reylo/migrations/"
run 0 "migrate dev applies it" reylo migrate dev
expect "dev applied the migration" "applied"
run 0 "migrate status is in step" reylo migrate status
seed > seed.sql
run 0 "run --file seed.sql" reylo run --file seed.sql

# Trying a change: push, then write the migration, which dev records without running.
schema published > reylo/schema.sql
run 0 "db push a new column" reylo db push
expect "push adds the column" "published_at"
run 0 "migrate dev before the migration exists" reylo migrate dev
expect "dev says the schema is ahead" "The schema is ahead of the migrations"
run 0 "migrate new add_published" reylo migrate new add_published
run 0 "migrate dev records the pushed change" reylo migrate dev
expect "dev records it as in place" "recorded: already in place"

# Drops are refused until named.
schema published nobody > reylo/schema.sql
run nonzero "migrate new drop_body is refused" reylo migrate new drop_body
expect "the refusal names the drop" "--drop posts.body"
run 0 "migrate new drop_body --drop posts.body" reylo migrate new drop_body --drop posts.body
run 0 "migrate dev runs the drop" reylo migrate dev

# A column replaced by one just like it is a rename.
schema published nobody headline > reylo/schema.sql
run 0 "migrate new rename_title" reylo migrate new rename_title
expect "new writes a rename" "Written as a rename"
run 0 "migrate dev runs the rename" reylo migrate dev
run 0 "the renamed column kept its rows" reylo run "select headline from posts"
run 0 "status after the renames" reylo migrate status

# An empty migration for a data change.
run 0 "migrate new backfill (empty)" reylo migrate new backfill
expect "new says it's empty" "Empty"
last="$(ls reylo/migrations/*_backfill.sql 2> /dev/null | head -1)"
if [ -n "$last" ]; then
  echo "update users set name = upper(name);" > "$last"
fi
run 0 "migrate dev runs the data change" reylo migrate dev

# Production: try, deploy, confirm.
run nonzero "status on the empty production database exits 1" reylo migrate status --url "$prod"
if [ "$dialect" = sqlite ]; then expect "status says the file is missing" "no SQLite database"; else expect "status lists pending migrations" "pending"; fi
run 0 "deploy --dry-run on production" reylo migrate deploy --dry-run --url "$prod"
run 0 "deploy on production" env CI=1 reylo migrate deploy --url "$prod"
expect "deploy applied the migrations" "Applied"
run 0 "status on production after deploy" reylo migrate status --url "$prod"
run 0 "deploy again is a no-op" reylo migrate deploy --url "$prod"

# A change made by hand on production is refused, then kept.
hotfix_type=bigint
[ "$dialect" = sqlite ] && hotfix_type=integer
run 0 "a hand change on production" reylo run --url "$prod" "alter table users add column hotfix $hotfix_type"
run nonzero "deploy refuses the hand change" reylo migrate deploy --url "$prod"
expect "the refusal shows the column" "hotfix"
run nonzero "status flags the hand change" reylo migrate status --url "$prod"
schema published nobody headline hotfix > reylo/schema.sql
run 0 "migrate new users_hotfix" reylo migrate new users_hotfix
run 0 "migrate dev runs it in development" reylo migrate dev
run 0 "history push records it on production" reylo migrate history push --url "$prod"
expect "history push recorded it" "recorded: already in place"
run 0 "status on production after history push" reylo migrate status --url "$prod"

# history pull brings a deleted migration back.
gone="$(ls reylo/migrations/*_users_hotfix.sql | head -1)"
cp "$gone" users_hotfix.bak && rm "$gone"
run 0 "history pull restores a deleted migration" reylo migrate history pull --url "$prod"
if cmp -s users_hotfix.bak "$gone"; then log "PASS [$dialect]   the restored file matches"; else failures=$((failures + 1)); log "FAIL [$dialect]   the restored file differs or is missing"; diff users_hotfix.bak "$gone" 2>&1 | head -20; fi
run 0 "status after history pull" reylo migrate status

# Starting over.
run 0 "db reset" reylo db reset
expect "reset rebuilt from the migrations" "Rebuilt from"
run 0 "db wipe" reylo db wipe
run 0 "db introspect" reylo db introspect
expect "introspect prints the posts table" "posts"
run nonzero "CI=1 refuses migrate dev" env CI=1 reylo migrate dev
run 0 "status --json" reylo migrate status --json
expect "json says ok" '"ok": true'

# Lock-free mode.
mv reylo/reylo.lock reylo.lock.bak
run 0 "status with no lock" reylo migrate status
expect "status says name order" "With no lock"
run 0 "migrate lock writes it again" reylo migrate lock
run 0 "status with the lock back" reylo migrate status

if [ "${E2E_NODE:-}" = 1 ]; then
  # The migrate() API from the npm package, deploying a pending migration at start.
  printf '{ "name": "e2e", "private": true, "type": "module" }\n' > package.json
  run 0 "npm install reylo@$version" npm install --no-audit --no-fund "reylo@$version"
  printf "\ncreate table page_views (id integer primary key, path varchar(200) not null);\n" >> reylo/schema.sql
  run 0 "migrate new views" reylo migrate new views
  run 0 "migrate dev runs it" reylo migrate dev
  printf 'import { migrate } from "reylo";\nconsole.log(JSON.stringify(await migrate({ url: process.argv[2] })));\n' > migrate.mjs
  run 0 "migrate() deploys the pending migration on production" node migrate.mjs "$prod"
  expect "migrate() resolved to its name" "_views.sql"
  run 0 "migrate() again resolves to nothing" node migrate.mjs "$prod"
  expect "migrate() again is empty" "[]"
  run 0 "another hand change on production" reylo run --url "$prod" "create index users_name on users (name)"
  run nonzero "migrate() rejects on the hand change" node migrate.mjs "$prod"
  show
fi

if [ "$failures" -eq 0 ]; then log "== $dialect: every step passed"; else log "== $dialect: $failures failed"; fi
[ "$failures" -eq 0 ]
