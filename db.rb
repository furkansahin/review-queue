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

  # libpq does NOT fall back to the operating system trust store. With a
  # verifying sslmode and no sslrootcert it reads only ~/.postgresql/root.crt,
  # which exists on a laptop and does not exist in the container -- so an
  # ordinary Let's Encrypt certificate verifies with psql locally and fails
  # here with "certificate verify failed".
  #
  # sslrootcert=system (PostgreSQL 16+; the bundled libpq is 18) points it at
  # the OS roots. It is added unconditionally when absent: with a non-verifying
  # sslmode libpq simply ignores it, so there is nothing to guard against, and
  # guarding on the sslmode text missed libpq's keyword/value form.
  #
  # DATABASE_URL may be either form:
  #   postgres://user:pw@host:5432/db?sslmode=verify-full
  #   host=... port=5432 dbname=... sslmode=verify-full
  #
  # RQ_DB_CA_CERT overrides with a PEM, for a database issued by a private CA.
  def url
    raw = ENV["DATABASE_URL"].to_s.strip
    raise Error, "DATABASE_URL is not set" if raw.empty?
    return raw if raw.match?(/(?:\A|[?&\s])sslrootcert=/)

    ca = ENV["RQ_DB_CA_CERT"].to_s.strip
    bundled = File.expand_path("db-ca.pem", __dir__)
    root =
      if !ca.empty? then ca_path(ca)
      elsif File.exist?(bundled) then bundled
      else "system"
      end

    if raw.match?(%r{\Apostgres(?:ql)?://})
      uri = URI.parse(raw)
      query = URI.decode_www_form(uri.query.to_s)
      query << ["sslrootcert", root]
      uri.query = URI.encode_www_form(query)
      uri.to_s
    else
      "#{raw} sslrootcert=#{root}"   # keyword/value form
    end
  end

  # What we actually decided, with no credentials in it. Printed once at boot so
  # a TLS failure says which knobs were in play.
  def describe
    raw = ENV["DATABASE_URL"].to_s
    form = raw.match?(%r{\Apostgres(?:ql)?://}) ? "uri" : "keyword/value"
    host = raw[%r{//[^/@]*@([^/:?\s]+)}, 1] || raw[/(?:\A|\s)host=(\S+)/, 1] || "?"
    mode = url[/(?:\A|[?&\s])sslmode=([^&\s]+)/, 1] || "(unset, libpq default)"
    root = url[/(?:\A|[?&\s])sslrootcert=([^&\s]+)/, 1] || "(none)"
    "database: form=#{form} host=#{host} sslmode=#{mode} sslrootcert=#{root}"
  end

  def ca_path(pem)
    require "tmpdir"
    path = File.join(Dir.tmpdir, "rq-db-ca.pem")
    body = pem.end_with?("\n") ? pem : pem + "\n"
    File.write(path, body) unless File.exist?(path) && File.read(path) == body
    File.chmod(0o600, path)
    path
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
      login       text PRIMARY KEY,
      updated_at  timestamptz NOT NULL DEFAULT now()
    );

    -- One remote dev box per user. The dashboard connects to it to start a bay
    -- session, so it holds a private key -- generated here, never uploaded by
    -- the user, encrypted at rest, and usable only for the forced command that
    -- the user installs on their box.
    CREATE TABLE IF NOT EXISTS dev_boxes (
      id              bigserial PRIMARY KEY,
      login           text        NOT NULL,
      host            text        NOT NULL,
      ssh_user        text        NOT NULL DEFAULT 'ubi',
      port            integer     NOT NULL DEFAULT 22,
      private_key_enc text        NOT NULL,
      public_key      text        NOT NULL,
      host_fingerprint text,
      last_ok_at      timestamptz,
      last_error      text,
      created_at      timestamptz NOT NULL DEFAULT now()
    );

    CREATE UNIQUE INDEX IF NOT EXISTS dev_boxes_login_idx ON dev_boxes (login);

    CREATE TABLE IF NOT EXISTS review_jobs (
      id          bigserial   PRIMARY KEY,
      login       text        NOT NULL,
      dev_box_id  bigint      REFERENCES dev_boxes (id) ON DELETE SET NULL,
      repo        text        NOT NULL,
      pr_number   integer     NOT NULL,
      box_name    text        NOT NULL,
      state       text        NOT NULL DEFAULT 'queued',
      output      text,
      error       text,
      created_at  timestamptz NOT NULL DEFAULT now(),
      started_at  timestamptz,
      finished_at timestamptz
    );

    CREATE INDEX IF NOT EXISTS review_jobs_login_idx ON review_jobs (login, created_at DESC);
    CREATE INDEX IF NOT EXISTS review_jobs_state_idx ON review_jobs (state);
    -- one live job per pull request per user, so a double click cannot start
    -- two bay boxes for the same review
    CREATE UNIQUE INDEX IF NOT EXISTS review_jobs_live_idx
      ON review_jobs (login, repo, pr_number)
      WHERE state IN ('queued', 'running');
  SQL

  def setup!
    with { |c| c.exec(SCHEMA) }
    true
  end
end
