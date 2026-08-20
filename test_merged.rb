#!/usr/bin/env ruby
# Merged tab tests:  bundle exec ruby test_merged.rb
require_relative "queue_service"

ME = "furkansahin"
$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-22s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 22], want.inspect[0, 22])
end

# Record every path the service asks for, and answer each one.
$asked = []
def stub_github(svc, merged_items:, open_items: [], pulls: {})
  gh = svc.instance_variable_get(:@gh)
  gh.define_singleton_method(:rate_remaining) { 5000 }
  answer = lambda do |path|
    $asked << path
    case path
    when "/user" then {"login" => ME}
    when %r{/search/issues.*is\+merged|/search/issues.*is%3Amerged}
      {"items" => merged_items}
    when %r{/search/issues} then {"items" => open_items}
    when %r{/repos/([^/]+)/([^/]+)/pulls/(\d+)\z} then pulls[$3.to_i]
    end
  end
  gh.define_singleton_method(:get) { |p| answer.call(p) }
  gh.define_singleton_method(:try) { |p| answer.call(p) }
end

def item(n, title, labels: [])
  {"number" => n, "title" => title, "html_url" => "https://github.com/o/r/pull/#{n}",
   "repository_url" => "https://api.github.com/repos/o/r", "user" => {"login" => ME},
   "labels" => labels.map { |l| {"name" => l} },
   "pull_request" => {"merged_at" => (Time.now - 3 * 86_400).utc.iso8601}}
end

svc = QueueService.new(token: "x", scope: "org:ubicloud", label: "clickhouse", merged_limit: 5)

puts "-- the query --"
q = svc.merged_query
check("scoped", q.include?("org:ubicloud"), true)
check("merged only", q.include?("is:merged"), true)
check("authored by the signed-in user", q.include?("author:@me"), true)
check("not restricted to open", q.include?("is:open"), false)

puts "-- rows --"
stub_github(svc, merged_items: [item(11, "Older", labels: ["clickhouse"]), item(12, "Newer")],
                 pulls: {11 => {"additions" => 30, "deletions" => 12, "changed_files" => 4,
                                "merged_at" => (Time.now - 9 * 86_400).utc.iso8601,
                                "merged_by" => {"login" => "mohi-kalantari"}},
                         12 => {"additions" => 1, "deletions" => 1, "changed_files" => 1,
                                "merged_at" => (Time.now - 1 * 86_400).utc.iso8601,
                                "merged_by" => {"login" => ME}}})
rows = svc.send(:merged_rows, [item(11, "Older"), item(12, "Newer")], ME)
check("one row per merged pull request", rows.size, 2)
check("newest merge first", rows.first[:number], 12)
check("state is Merged", rows.first[:state], "Merged")
check("size comes from the pull", rows.last[:size_sub], "±42 · 4f")
check("read estimate is shown", rows.last[:read_est].start_with?("~"), true)
check("merged by someone else names them", rows.last[:reviewers], "mohi-kalantari")
check("merged by me says you", rows.first[:reviewers], "you")
check("every merged row is settled", rows.all? { |r| r[:settled] }, true)
check("and belongs to no bucket", rows.all? { |r| r[:buckets].empty? }, true)
check("key matches the queue's key shape", rows.first[:key], "o/r#12")

puts "-- a merged pull request must not reach the queue --"
# This is the whole design risk. A merged row inside snap[:rows] would be
# counted in All, would be drawn into the progress bar as work still to do,
# and would cost six API calls each to decide a review state it cannot have.
fresh = QueueService.new(token: "x", scope: "org:ubicloud", label: "", merged_limit: 5)
stub_github(fresh, merged_items: [item(11, "Older"), item(12, "Newer")], open_items: [],
                   pulls: {11 => {"additions" => 2, "deletions" => 0, "changed_files" => 1},
                           12 => {"additions" => 2, "deletions" => 0, "changed_files" => 1}})
snap = fresh.send(:build)
check("the queue itself stays empty", snap[:rows], [])
check("the merged list is its own", snap[:merged].size, 2)
check("All counts no merged work", snap[:counts][:all][:total], 0)
check("and neither does My PRs", snap[:counts][:mine][:total], 0)
check("nothing asked for a review of a merged pull request",
      $asked.any? { |a| a.include?("/reviews") }, false)

puts "-- the page renders it --"
require "tilt"
require "erubi"
tpl = Tilt::ErubiTemplate.new("views/queue.erb", escape: true)
page = tpl.render(Object.new, {
  snap: snap.merge(counts: snap[:counts].merge(merged: {open: nil, total: snap[:merged].size})),
  rows: snap[:merged], tab: :merged, hide: false, service: fresh, login: ME,
  csrf: "", csrf_logout: "", csrf_snooze: "", csrf_settings: "", suggested_label: "",
  reviews_enabled: true, review_error: nil, has_dev_box: true, csrf_review: "",
  jobs_by_key: {}, csrf_unsnooze: "", snooze: nil
})
check("both merged titles are on the page", ["Older", "Newer"].all? { |t| page.include?(t) }, true)
check("the Merged pill is drawn", page.include?(">Merged<"), true)
check("no Review button on finished work", page.include?("start an adversarial review"), false)
check("no Snooze button either", page.include?("Hide until there is new activity"), false)
check("no Next up hero", page.include?("Next up"), false)
check("the badge shows a plain total", page.include?(">2</span>"), true)

puts "-- the tab is registered --"
keys = svc.tabs.map { |t| t[:key] }
check("merged is a tab", keys.include?(:merged), true)
check("it comes after the queue tabs", keys.last, :merged)
check("the label reads Merged", svc.tabs.find { |t| t[:key] == :merged }[:label], "Merged")

puts "-- a failed lookup degrades, it does not raise --"
gh = svc.instance_variable_get(:@gh)
gh.define_singleton_method(:try) { |_p| nil }
quiet = svc.send(:merged_rows, [item(13, "No detail")], ME)
check("the row still exists without its pull", quiet.size, 1)
check("and says so instead of a size", quiet.first[:size_sub], "no diff data")
check("falling back to the search's merged_at", quiet.first[:age].end_with?("d"), true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
