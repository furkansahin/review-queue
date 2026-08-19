require "pg"
require "uri"

# A small connection pool over DATABASE_URL. Puma serves requests on several
# threads and the worker runs in its own process, so every caller must get its
# own connection while it works.
module DB
  class Error < StandardError; end

  POOL_SIZE = Integer(ENV.fetch("RQ_DB_POOL", "5"))

  @pool = []
  @lock = Mutex.new
  @created = 0
  @cv = ConditionVariable.new

  module_function

  def url
    raw = ENV["DATABASE_URL"].to_s
    raise Error, "DATABASE_URL is not set" if raw.empty?
    raw
  end

  def new_connection
    conn = PG.connect(url)
    conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)
    conn
  end

  # Hands a connection to the block and always returns it to the pool.
  def with
    conn = checkout
    begin
      yield conn
    ensure
      checkin(conn)
    end
  end

  def checkout
    @lock.synchronize do
      loop do
        return @pool.pop unless @pool.empty?
        if @created < POOL_SIZE
          @created += 1
          begin
            return new_connection
          rescue StandardError
            @created -= 1
            raise
          end
        end
        @cv.wait(@lock, 5)
      end
    end
  end

  def checkin(conn)
    @lock.synchronize do
      # A connection that died is dropped, so the next caller opens a fresh one.
      if conn.nil? || conn.finished? || conn.status != PG::CONNECTION_OK
        @created -= 1
        conn&.close rescue nil
      else
        @pool.push(conn)
      end
      @cv.signal
    end
  end

  def exec(sql, params = [])
    with { |c| c.exec_params(sql, params) }
  end

  # Returns rows as an array of hashes with string keys.
  def rows(sql, params = []) = exec(sql, params).to_a

  def row(sql, params = []) = rows(sql, params).first

  def reset_pool!
    @lock.synchronize do
      @pool.each { |c| c.close rescue nil }
      @pool = []
      @created = 0
    end
  end

  SCHEMA = <<~SQL
    CREATE TABLE IF NOT EXISTS user_settings (
      login               text PRIMARY KEY,
      ubicloud_pat_enc    text,
      ubicloud_project_id text,
      anthropic_key_enc   text,
      -- a PUBLIC key, so it is not a secret and is stored in the clear. The
      -- dashboard never holds a private key for any machine.
      ssh_public_key      text,
      boot_image          text,
      vm_size             text,
      vm_location         text,
      updated_at          timestamptz NOT NULL DEFAULT now()
    );

    -- A runner is a long lived VM that keeps a warm checkout and runs several
    -- Claude sessions at once. The agent on the VM polls for work, so the
    -- dashboard never opens a connection to it and stores no key for it.
    CREATE TABLE IF NOT EXISTS runners (
      id               bigserial PRIMARY KEY,
      login            text        NOT NULL,
      name             text        NOT NULL,
      vm_id            text,
      location         text        NOT NULL,
      size             text,
      vm_state         text,
      ip4              text,
      agent_token_hash text        NOT NULL,
      max_sessions     integer     NOT NULL DEFAULT 3,
      last_seen_at     timestamptz,
      created_at       timestamptz NOT NULL DEFAULT now()
    );

    CREATE UNIQUE INDEX IF NOT EXISTS runners_login_name_idx ON runners (login, name);
    CREATE INDEX IF NOT EXISTS runners_login_idx ON runners (login);

    CREATE TABLE IF NOT EXISTS review_jobs (
      id                  bigserial PRIMARY KEY,
      login               text        NOT NULL,
      repo                text        NOT NULL,
      pr_number           integer     NOT NULL,
      state               text        NOT NULL DEFAULT 'queued',
      runner_id           bigint      REFERENCES runners (id) ON DELETE SET NULL,
      -- stored hashed, so reading the database does not let anyone post a
      -- false result for a job
      callback_token_hash text        NOT NULL,
      result              text,
      error               text,
      created_at          timestamptz NOT NULL DEFAULT now(),
      claimed_at          timestamptz,
      finished_at         timestamptz
    );

    CREATE INDEX IF NOT EXISTS review_jobs_login_idx ON review_jobs (login, created_at DESC);
    CREATE INDEX IF NOT EXISTS review_jobs_state_idx ON review_jobs (state);
    -- one live job per pull request per user, so a double click cannot start
    -- two reviews of the same thing
    CREATE UNIQUE INDEX IF NOT EXISTS review_jobs_live_idx
      ON review_jobs (login, repo, pr_number)
      WHERE state IN ('queued', 'claimed', 'running');

    -- Idempotent column adds, so an existing database moves forward too.
    ALTER TABLE user_settings ADD COLUMN IF NOT EXISTS ssh_public_key text;
    ALTER TABLE review_jobs   ADD COLUMN IF NOT EXISTS runner_id  bigint;
    ALTER TABLE review_jobs   ADD COLUMN IF NOT EXISTS claimed_at timestamptz;
  SQL

  def setup!
    with { |c| c.exec(SCHEMA) }
    true
  end
end
