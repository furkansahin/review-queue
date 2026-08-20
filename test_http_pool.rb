#!/usr/bin/env ruby
# GitHubClient connection reuse:  bundle exec ruby test_http_pool.rb
#
# A rebuild makes about six calls per pull request, and opening a connection
# for each one threw away a TCP and TLS handshake every time -- measured
# against api.github.com at ~130 ms of the ~390 ms a call took. These assert
# the connection is actually reused, and that reuse cannot lose a request when
# the far end closes an idle socket.
require "socket"
require "json"
require_relative "queue_service"

$fails = 0
def check(name, got, want)
  ok = got == want
  $fails += 1 unless ok
  puts format("  %-4s  %-52s got=%-16s want=%s", ok ? "ok" : "FAIL", name,
              got.inspect[0, 16], want.inspect[0, 16])
end

# A minimal HTTP/1.1 server that counts connections and requests, and can be
# told to hang up after a set number of requests on a connection.
class CountingServer
  attr_reader :port

  def initialize(close_after: nil)
    @close_after = close_after
    @lock = Mutex.new
    @connections = 0
    @requests = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @threads = []
    @acceptor = Thread.new { accept_loop }
  end

  def stats = @lock.synchronize { {connections: @connections, requests: @requests} }

  def stop
    begin; @server.close; rescue StandardError; end
    @acceptor.kill
    @threads.each(&:kill)
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      @lock.synchronize { @connections += 1 }
      @threads << Thread.new(sock) { |s| serve(s) }
    end
  rescue StandardError
    nil
  end

  def serve(sock)
    served = 0
    while sock.gets
      while (h = sock.gets) && h.strip != ""; end
      served += 1
      @lock.synchronize { @requests += 1 }
      # Hang up mid-conversation, the way an idle keep-alive connection is
      # dropped by the far end.
      if @close_after && served > @close_after
        sock.close
        return
      end
      body = JSON.generate({"ok" => served})
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "x-ratelimit-remaining: 4321\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    end
  rescue StandardError
    nil
  ensure
    begin; sock.close; rescue StandardError; end
  end
end

# --- one connection serves many requests -------------------------------------
srv = CountingServer.new
gh = GitHubClient.new("t")
base = "http://127.0.0.1:#{srv.port}"

10.times { |i| gh.get("#{base}/thing/#{i}") }
s = srv.stats
check("ten calls were served", s[:requests], 10)
check("over a single connection", s[:connections], 1)
check("and the rate limit header is still read", gh.rate_remaining, "4321")
gh.close_idle
srv.stop

# --- a dropped idle connection costs a retry, not a request ------------------
srv = CountingServer.new(close_after: 3)
gh = GitHubClient.new("t")
base = "http://127.0.0.1:#{srv.port}"

results = 6.times.map { |i| gh.get("#{base}/thing/#{i}") }
check("every call still returned a body", results.compact.size, 6)
check("the server had to be reconnected to", srv.stats[:connections] > 1, true)
gh.close_idle
srv.stop

# --- concurrent callers never share a connection -----------------------------
# The fetch runs on a pool of threads, and Net::HTTP is not thread-safe, so two
# threads must never hold the same connection at once. If they did, the replies
# would cross and the bodies would not match the requests.
srv = CountingServer.new
gh = GitHubClient.new("t")
base = "http://127.0.0.1:#{srv.port}"

errors = []
threads = 8.times.map do
  Thread.new do
    20.times { gh.get("#{base}/thing") }
  rescue StandardError => e
    errors << e
  end
end
threads.each(&:join)
s = srv.stats
check("nothing failed under concurrency", errors.map { |e| e.message }, [])
check("all requests were served", s[:requests], 160)
check("with a bounded number of connections", s[:connections] <= 8, true)
check("and it did reuse them", s[:connections] < 160, true)
gh.close_idle
srv.stop

# --- a real failure is still a failure ---------------------------------------
gh = GitHubClient.new("t")
begin
  gh.get("http://127.0.0.1:1/nothing-listening")
  check("a refused connection raises", false, true)
rescue StandardError
  check("a refused connection raises", true, true)
end
check("and try swallows it", gh.try("http://127.0.0.1:1/nothing-listening"), nil)

puts($fails.zero? ? "\nALL PASS" : "\n#{$fails} FAILURE(S)")
exit($fails.zero? ? 0 : 1)
