#!/usr/bin/env ruby
# Linear client tests:  bundle exec ruby test_linear.rb
require_relative "linear"
require "json"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-26s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,26], want.inspect[0,26])
end
def raises(k)
  yield
  "no error"
rescue k => e
  e.message
end

ISSUE = {"identifier" => "UBI-336", "title" => "Storage thing", "url" => "https://linear.app/x",
         "priority" => 2, "updatedAt" => "2026-08-01T00:00:00Z",
         "state" => {"name" => "In Review", "type" => "started"},
         "assignee" => {"displayName" => "furkan"},
         "labels" => {"nodes" => [{"name" => "storage"}]}}

calls = []
stub = lambda do |body|
  calls << JSON.parse(body)
  q = JSON.parse(body)["query"]
  case q
  when /attachments/ then {"attachments" => {"nodes" => [
    {"url" => "https://github.com/ubicloud/ubicloud/pull/4497", "issue" => ISSUE},
    {"url" => "https://github.com/ubicloud/ubicloud/issues/6163", "issue" => ISSUE},
    {"url" => "https://example.com/other", "issue" => nil}]}}
  when /users/ then {"users" => {"nodes" => [{"id" => "u1", "displayName" => "furkan", "email" => "furkan@ubicloud.com"}]}}
  else {"issues" => {"nodes" => [ISSUE]}}
  end
end
lin = Linear.new(api_key: "k", http: stub, ttl: 300)

check("missing key is refused", raises(Linear::Error) { Linear.new(api_key: "") }, "missing Linear API key")

i = lin.open_issues.first
check("issue is flattened", [i[:identifier], i[:state], i[:assignee]], ["UBI-336", "In Review", "furkan"])
check("labels come through", i[:labels], ["storage"])

# the attachment join: pull requests only, keyed the same way the queue keys rows
m = lin.issues_by_pull_request
check("attachment join keys by owner/repo#n", m.keys, ["ubicloud/ubicloud#4497"])
check("github ISSUE attachments are ignored", m.key?("ubicloud/ubicloud#6163"), false)
check("attachments with no issue do not crash", m.size, 1)

check("canonical url ignores query strings",
      lin.canonical_pr("https://github.com/o/r/pull/12?w=1#discussion"), "o/r#12")
check("a non-github url is passed through", lin.canonical_pr("nonsense"), "nonsense")

# the convention join
check("finds an identifier in a branch name",
      Linear.referenced_identifier("furkan/ubi-336-storage", nil, nil), "UBI-336")
check("finds one in a title", Linear.referenced_identifier(nil, "Fix UBI-42 crash", nil), "UBI-42")
check("nil when nothing references an issue",
      Linear.referenced_identifier("better-csi-var-management", "Better csi var management", ""), nil)
check("does not match a bare word", Linear.referenced_identifier("ubi_admin grant", nil, nil), nil)

by = lin.issues_by_identifier(["UBI-336", "UBI-999"])
check("resolves identifiers it was given", by.keys, ["UBI-336"])
check("an unknown identifier is simply absent", by["UBI-999"], nil)
check("empty input makes no request", lin.issues_by_identifier([]), {})

# caching, because Linear rate limits
before = calls.size
lin.open_issues
check("a repeat call is served from cache", calls.size, before)

# an api error surfaces as our own error
bad = Linear.new(api_key: "k", http: ->(_) { raise Linear::Error, "Linear: rate limited" })
check("api errors surface", raises(Linear::Error) { bad.open_issues }, "Linear: rate limited")

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
