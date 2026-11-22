#!/usr/bin/env bash
# rust.sh <postgres|mysql|sqlite> <work dir>: a new Rust app on reylo's crate, whose migrations run
# through reylo::migrate!(), as reylo.dev/rust and reylo.dev/migrate/docs#api describe it. The reylo
# command (cargo binstall reylo-cli) must be on PATH. For postgres and mysql, E2E_SERVER names a server
# whose account may create databases.
set -euxo pipefail
dialect="$1"
work="$2"
version="${REYLO_VERSION:-0.8.2}"
suffix="$(date +%s)"

case "$dialect" in
  postgres)
    reylo run --url "$E2E_SERVER/postgres" "create database rs_dev_$suffix" "create database rs_prod_$suffix"
    dev="$E2E_SERVER/rs_dev_$suffix" prod="$E2E_SERVER/rs_prod_$suffix"
    pool=PgPool
    id="bigint generated always as identity primary key" email="text not null unique"
    insert="insert into users (email) values (:email) returning id"
    ;;
  mysql)
    reylo run --url "$E2E_SERVER" "create database rs_dev_$suffix" "create database rs_prod_$suffix"
    dev="$E2E_SERVER/rs_dev_$suffix" prod="$E2E_SERVER/rs_prod_$suffix"
    pool=MySqlPool
    id="bigint not null auto_increment primary key" email="varchar(255) not null unique"
    insert="insert into users (email) values (:email)"
    ;;
  sqlite)
    dev="sqlite:./dev.db" prod="sqlite:./prod.db?mode=rwc"
    pool=SqlitePool
    id="integer primary key" email="text not null unique"
    insert="insert into users (email) values (:email) returning id"
    ;;
esac

rm -rf "$work"
cargo new -q "$work"
cd "$work"
cat >> Cargo.toml <<TOML
reylo = { version = "$version", default-features = false, features = ["sqlx_0_9", "$dialect", "migrate"] }
sqlx = { version = "0.9", features = ["runtime-tokio", "$dialect"] }
tokio = { version = "1", features = ["full"] }
TOML
echo "DATABASE_URL=$dev" > .env

reylo migrate init
printf 'create table users (\n  id %s,\n  email %s\n);\n' "$id" "$email" > reylo/schema.sql
reylo migrate new users
reylo migrate dev

cat > src/main.rs <<RS
#[reylo::query("$insert")]
pub mod add_user {}

#[reylo::query("select id, email from users where email = :email")]
pub mod find_user {}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let pool = sqlx::$pool::connect(&std::env::var("PROD_URL")?).await?;
    let ran = reylo::migrate!().run(&pool).await?;
    println!("ran: {ran:?}");
    let status = reylo::migrate!().status(&pool).await?;
    println!("current: {}", status.is_current());
    let email = format!("ada{}@example.com", std::process::id());
    let _ = add_user::Query { email: &email }.run(&pool).await?;
    let found = find_user::Query { email: &email }.run(&pool).await?;
    println!("found {found:?}");
    assert!(found.is_some());
    Ok(())
}
RS

export PROD_URL="$prod"
time cargo build -q
cargo run -q | tee run1.txt
grep -q 'ran: \["' run1.txt
cargo run -q | tee run2.txt
grep -q 'ran: \[\]' run2.txt

# A new migration: the lock changes, so the crate compiles again and the app runs it.
printf '\ncreate table posts (\n  id %s,\n  title %s\n);\n' "$id" "$email" >> reylo/schema.sql
reylo migrate new posts
reylo migrate dev
cargo run -q | tee run3.txt
grep -q '_posts.sql' run3.txt
echo "RUST $dialect: every step passed"
