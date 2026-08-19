#!/usr/bin/env ruby
# Ubicloud client tests:  bundle exec ruby test_ubicloud.rb
require_relative "ubicloud"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-50s got=%-30s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,30], want.inspect[0,30])
end
def raises(klass)
  yield
  "no error"
rescue klass => e
  e.message
end

seen = []
stub = lambda do |method, path, body|
  seen << [method, path, body]
  {"id" => "vm123", "state" => "creating", "ip4" => nil}
end
u = Ubicloud.new(token: "pat", project_id: "pj1", http: stub)

u.create_vm(name: "rq-runner", location: "eu-central-h1", public_key: "ssh-ed25519 AAA user@host",
            boot_image: "ubuntu-noble", size: "standard-4", storage_size: 40,
            init_script: "#!/bin/bash\necho hi")
m, path, body = seen.last
check("create uses POST", m, :post)
check("create path is right", path, "/project/pj1/location/eu-central-h1/vm/rq-runner")
check("init_script is sent", body[:init_script].include?("echo hi"), true)
check("public_key is sent", body[:public_key].start_with?("ssh-ed25519"), true)
check("size is sent", body[:size], "standard-4")

u.stop_vm(name: "rq-runner", location: "eu-central-h1")
check("stop path", seen.last[1], "/project/pj1/location/eu-central-h1/vm/rq-runner/stop")
u.start_vm(name: "rq-runner", location: "eu-central-h1")
check("start path", seen.last[1], "/project/pj1/location/eu-central-h1/vm/rq-runner/start")
u.delete_vm(name: "rq-runner", location: "eu-central-h1")
check("delete uses DELETE", seen.last[0], :delete)
u.list_vms
check("list path", seen.last[1], "/project/pj1/vm")

# optional fields must not be sent as nulls
seen.clear
u.create_vm(name: "n", location: "l", public_key: "k")
check("omits unset optional fields", seen.last[2].keys.sort, [:public_key])

# values that need escaping must not break the path
esc = Ubicloud.new(token: "t", project_id: "pj/../admin", http: stub)
esc.list_vms
check("project id is escaped", seen.last[1], "/project/pj%2F..%2Fadmin/vm")

# construction guards
check("empty token refused", raises(Ubicloud::Error) { Ubicloud.new(token: "", project_id: "p") }, "missing Ubicloud token")
check("empty project refused", raises(Ubicloud::Error) { Ubicloud.new(token: "t", project_id: "") }, "missing Ubicloud project id")

# error mapping, exercised through the real handler
real = Ubicloud.new(token: "t", project_id: "p")
h = real.method(:handle)
check("2xx returns the body", h.call(200, '{"id":"vm1"}'), {"id" => "vm1"})
check("204 with empty body is fine", h.call(204, ""), {})
check("401 is an AuthError", raises(Ubicloud::AuthError) { h.call(401, '{"error":{"message":"bad token"}}') },
      "Ubicloud rejected the token: bad token")
check("403 is an AuthError", (begin; h.call(403, "{}"); rescue => e; e.class; end), Ubicloud::AuthError)
check("404 is a plain Error", (begin; h.call(404, '{"error":{"message":"not found"}}'); rescue => e; e.message; end),
      "Ubicloud API 404: not found")
check("status is kept on the error", (begin; h.call(500, "{}"); rescue => e; e.status; end), 500)
check("html error body does not crash", (begin; h.call(502, "<html>bad gateway</html>"); rescue => e; e.message; end),
      "Ubicloud API 502: HTTP 502")

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
