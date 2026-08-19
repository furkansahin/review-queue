#!/usr/bin/env ruby
# Database tests:  DATABASE_URL=... bundle exec ruby test_db.rb
ENV["DATABASE_URL"] ||= "postgres://postgres@127.0.0.1:55432/rq_test"
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
require_relative "db"
require_relative "crypto"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,22], want.inspect[0,22])
end

DB.exec("DROP TABLE IF EXISTS review_jobs, user_settings CASCADE")
check("setup! applies the schema", DB.setup!, true)
check("setup! is idempotent", DB.setup!, true)

# --- settings round trip, with the secret encrypted at rest -----------------
pat = "ubi_pat_secret_value_123"
DB.exec(<<~SQL, ["furkansahin", Crypto.encrypt(pat), "pj123"])
  INSERT INTO user_settings (login, ubicloud_pat_enc, ubicloud_project_id)
  VALUES ($1, $2, $3)
  ON CONFLICT (login) DO UPDATE SET ubicloud_pat_enc = EXCLUDED.ubicloud_pat_enc,
                                    ubicloud_project_id = EXCLUDED.ubicloud_project_id
SQL
r = DB.row("SELECT * FROM user_settings WHERE login = $1", ["furkansahin"])
check("pat decrypts back", Crypto.decrypt(r["ubicloud_pat_enc"]), pat)
check("plaintext is NOT in the column", r["ubicloud_pat_enc"].include?(pat), false)

# --- jobs -------------------------------------------------------------------
tok = Crypto.token
job = DB.row(<<~SQL, ["furkansahin", "ubicloud/ubicloud", 6172, Crypto.hash_token(tok)])
  INSERT INTO review_jobs (login, repo, pr_number, callback_token_hash)
  VALUES ($1, $2, $3, $4) RETURNING *
SQL
check("job starts queued", job["state"], "queued")
check("pr_number is an integer", job["pr_number"], 6172)
check("token is stored hashed", job["callback_token_hash"].include?(tok), false)
check("hash verifies", Crypto.secure_equal?(job["callback_token_hash"], Crypto.hash_token(tok)), true)

# a second live job for the same PR must be refused
dup = begin
  DB.exec(<<~SQL, ["furkansahin", "ubicloud/ubicloud", 6172, Crypto.hash_token(Crypto.token)])
    INSERT INTO review_jobs (login, repo, pr_number, callback_token_hash) VALUES ($1, $2, $3, $4)
  SQL
  "inserted"
rescue PG::UniqueViolation
  "refused"
end
check("double click cannot start two VMs", dup, "refused")

# once finished, a new job for the same PR is allowed again
DB.exec("UPDATE review_jobs SET state = 'done', finished_at = now() WHERE id = $1", [job["id"]])
again = begin
  DB.exec(<<~SQL, ["furkansahin", "ubicloud/ubicloud", 6172, Crypto.hash_token(Crypto.token)])
    INSERT INTO review_jobs (login, repo, pr_number, callback_token_hash) VALUES ($1, $2, $3, $4)
  SQL
  "inserted"
rescue PG::UniqueViolation
  "refused"
end
check("a finished job frees the pull request", again, "inserted")

# another user is unaffected by the first user's live job
other = begin
  DB.exec(<<~SQL, ["mohi-kalantari", "ubicloud/ubicloud", 6172, Crypto.hash_token(Crypto.token)])
    INSERT INTO review_jobs (login, repo, pr_number, callback_token_hash) VALUES ($1, $2, $3, $4)
  SQL
  "inserted"
rescue PG::UniqueViolation
  "refused"
end
check("the limit is per user", other, "inserted")

# --- the pool must survive concurrent use -----------------------------------
errors = Queue.new
threads = 12.times.map do
  Thread.new do
    20.times { DB.row("SELECT count(*)::int AS n FROM review_jobs") }
  rescue StandardError => e
    errors << e
  end
end
threads.each(&:join)
check("pool survives 12 threads x 20 queries", errors.empty?, true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
