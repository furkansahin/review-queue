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

  # libpq does NOT fall back to the operating system trust store. With
  # sslmode=verify-full and no sslrootcert it reads only ~/.postgresql/root.crt,
  # which does not exist in the container -- so a perfectly ordinary Let's
  # Encrypt certificate fails with "certificate verify failed", even though the
  # same URL works from a laptop whose libpq has that file.
  #
  # sslrootcert=system (PostgreSQL 16+) points it at the OS trust store, which
  # already contains the public roots.
  #
  # RQ_DB_CA_CERT stays as an override for a database issued by a private CA:
  # set it to the PEM and that is used instead. A URL that already names an
  # sslrootcert is left exactly as given.
  def url
    raw = ENV["DATABASE_URL"].to_s
    raise Error, "DATABASE_URL is not set" if raw.empty?
    return raw if raw.include?("sslrootcert=")
    return raw unless raw[/[?&]sslmode=(verify-full|verify-ca)/]

    ca = ENV["RQ_DB_CA_CERT"].to_s.strip
    with_params(raw, sslrootcert: ca.empty? ? "system" : ca_path(ca))
  end

  def ca_path(pem)
    require "tmpdir"
    path = File.join(Dir.tmpdir, "rq-db-ca.pem")
    body = pem.end_with?("\n") ? pem : pem + "\n"
    File.write(path, body) unless File.exist?(path) && File.read(path) == body
    File.chmod(0o600, path)
    path
  end

  def with_params(raw, **params)
    uri = URI.parse(raw)
    query = URI.decode_www_form(uri.query.to_s).reject { |k, _| params.key?(k.to_sym) }
    params.each { |k, v| query << [k.to_s, v.to_s] }
    uri.query = URI.encode_www_form(query)
    uri.to_s
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
