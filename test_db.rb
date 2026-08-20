#!/usr/bin/env ruby
# Database tests:  DATABASE_URL=... bundle exec ruby test_db.rb
ENV["DATABASE_URL"] ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
require_relative "db"
require_relative "crypto"
require_relative "devbox"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  $stdout.puts format("  %s  %-52s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,22], want.inspect[0,22])
end

DB.exec("DROP TABLE IF EXISTS review_jobs, runners, dev_boxes, user_settings CASCADE")
check("setup! applies the schema", DB.setup!, true)
check("setup! is idempotent", DB.setup!, true)

# An EXISTING table must gain new columns. CREATE TABLE IF NOT EXISTS does
# nothing to one that is already there, so a column added only to the CREATE
# never reaches a live database -- which is how torn_down_at shipped missing and
# every teardown raised PG::UndefinedColumn. Dropping the table first, as the
# other tests do, hides exactly this.
DB.exec("ALTER TABLE review_jobs DROP COLUMN IF EXISTS torn_down_at")
DB.exec("ALTER TABLE review_jobs DROP COLUMN IF EXISTS phase")
DB.exec("ALTER TABLE dev_boxes DROP COLUMN IF EXISTS last_ok_at")
DB.setup!
%w[torn_down_at phase].each do |col|
  present = DB.row(<<~SQL, ["review_jobs", col])["n"]
    SELECT count(*)::int AS n FROM information_schema.columns
    WHERE table_name = $1 AND column_name = $2
  SQL
  check("setup! adds #{col} to an existing table", present, 1)
end
check("setup! adds last_ok_at to an existing dev_boxes",
      DB.row("SELECT count(*)::int AS n FROM information_schema.columns WHERE table_name='dev_boxes' AND column_name='last_ok_at'")["n"], 1)

# and every column the code selects must actually exist
%w[phase torn_down_at box_name dev_box_id output error].each do |col|
  ok = begin
    DB.exec("SELECT #{col} FROM review_jobs LIMIT 0")
    true
  rescue PG::Error
    false
  end
  check("review_jobs.#{col} is queryable", ok, true)
end

# --- a dev box, with its private key encrypted at rest ----------------------
priv, pub = DevBox.generate_keypair
box = DB.row(<<~SQL, ["furkansahin", "10.0.0.5", "ubi", 22, Crypto.encrypt(priv), pub])
  INSERT INTO dev_boxes (login, host, ssh_user, port, private_key_enc, public_key)
  VALUES ($1, $2, $3, $4, $5, $6) RETURNING *
SQL
check("private key decrypts back", Crypto.decrypt(box["private_key_enc"]) == priv, true)
check("the PEM is NOT stored in the clear", box["private_key_enc"].include?("BEGIN"), false)
check("the public key is stored as-is", box["public_key"], pub)

dup = begin
  DB.exec("INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4)",
          ["furkansahin", "10.0.0.9", "x", "y"])
  "inserted"
rescue PG::UniqueViolation
  "refused"
end
check("one dev box per user", dup, "refused")

# --- jobs -------------------------------------------------------------------
job = DB.row(<<~SQL, ["furkansahin", box["id"], "ubicloud/ubicloud", 6172, "rq-ubicloud-6172"])
  INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name)
  VALUES ($1, $2, $3, $4, $5) RETURNING *
SQL
check("job starts queued", job["state"], "queued")
check("job points at the dev box", job["dev_box_id"], box["id"])

second = begin
  DB.exec(<<~SQL, ["furkansahin", box["id"], "ubicloud/ubicloud", 6172, "rq-ubicloud-6172"])
    INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name) VALUES ($1,$2,$3,$4,$5)
  SQL
  "inserted"
rescue PG::UniqueViolation
  "refused"
end
check("double click cannot start two boxes", second, "refused")

DB.exec("UPDATE review_jobs SET state='done', finished_at=now() WHERE id=$1", [job["id"]])
again = begin
  DB.exec(<<~SQL, ["furkansahin", box["id"], "ubicloud/ubicloud", 6172, "rq-ubicloud-6172"])
    INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name) VALUES ($1,$2,$3,$4,$5)
  SQL
  "inserted"
rescue PG::UniqueViolation
  "refused"
end
check("a finished job frees the pull request", again, "inserted")

other = DB.row(<<~SQL, ["mohi-kalantari", "10.0.0.6", Crypto.encrypt("k"), "pub"])
  INSERT INTO dev_boxes (login, host, private_key_enc, public_key) VALUES ($1,$2,$3,$4) RETURNING *
SQL
o = begin
  DB.exec(<<~SQL, ["mohi-kalantari", other["id"], "ubicloud/ubicloud", 6172, "rq-ubicloud-6172"])
    INSERT INTO review_jobs (login, dev_box_id, repo, pr_number, box_name) VALUES ($1,$2,$3,$4,$5)
  SQL
  "inserted"
rescue PG::UniqueViolation
  "refused"
end
check("the limit is per user", o, "inserted")

# deleting a box must not delete that user's history
DB.exec("DELETE FROM dev_boxes WHERE id = $1", [other["id"]])
check("jobs survive removing a dev box",
      DB.row("SELECT count(*)::int n FROM review_jobs WHERE login=$1", ["mohi-kalantari"])["n"], 1)
check("the link is cleared, not orphaned",
      DB.row("SELECT dev_box_id FROM review_jobs WHERE login=$1", ["mohi-kalantari"])["dev_box_id"], nil)

# --- pool -------------------------------------------------------------------
errors = Queue.new
12.times.map { Thread.new { 20.times { DB.row("SELECT count(*)::int AS n FROM review_jobs") } rescue errors << $! } }.each(&:join)
check("pool survives 12 threads x 20 queries", errors.empty?, true)

# libpq waits with no limit by default. One database that answers the TCP
# connection but sends nothing then stops every request.
check("the URL sets a connect timeout", DB.send(:url).include?("connect_timeout="), true)

sing  = DB.singleton_class
orig  = sing.instance_method(:new_connection)
reset = -> { sing.send(:define_method, :new_connection) { orig.bind(DB).call } }
# Empty the pool, so the next checkout must open a connection instead of
# taking one that an earlier test left behind.
drain = lambda do
  DB.instance_variable_get(:@lock).synchronize do
    pool = DB.instance_variable_get(:@pool)
    pool.each { |c| c.close rescue nil }
    pool.clear
    DB.instance_variable_set(:@created, 0)
  end
end

# A connect that fails must give its slot back. Without this the pool shrinks
# to nothing after a database restart, and the application never recovers.
drain.call
sing.send(:define_method, :new_connection) { raise PG::ConnectionBad, "boom" }
30.times { DB.checkout rescue nil }
check("a failed connect leaks no slot", DB.instance_variable_get(:@created), 0)
reset.call

# The failure path must also send a signal. It gave the slot back but sent no
# signal before. Two threads wait for a slot. One slot becomes free, which wakes
# the first thread. That thread then fails to connect and gives the slot back.
# Without a signal the second thread stays asleep for the full 5 second timeout,
# although a slot is free.
drain.call
held = Array.new(DB::POOL_SIZE) { DB.checkout }   # every slot is taken, pool is empty
waits = Queue.new
two = 2.times.map do
  Thread.new do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    c = (DB.checkout rescue nil)
    waits << Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    DB.checkin(c) if c
  end
end
sleep 0.3                                         # both threads are now waiting
sing.send(:define_method, :new_connection) { raise PG::ConnectionBad, "boom" }
dead = held.pop
dead.close
DB.checkin(dead)                                  # frees one slot and wakes one thread
two.each(&:join)
slowest = [waits.pop, waits.pop].max
held.each { |c| DB.checkin(c) }
reset.call
check("a failed connect wakes the next waiter", slowest < 2.0, true)



# PG.connect must run outside @lock. It ran inside the lock before. One slow
# connect then blocked every other thread on the mutex.
drain.call
sing.send(:define_method, :new_connection) { sleep 2; orig.bind(DB).call }
slow = Thread.new { c = (DB.checkout rescue nil); DB.checkin(c) if c }
sleep 0.3
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
DB.instance_variable_get(:@lock).synchronize { nil }
blocked = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
slow.join
reset.call
check("a slow connect does not hold the pool lock", blocked < 0.5, true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
