#!/usr/bin/env ruby
# Live trace tests:  bundle exec ruby test_render.rb
require "json"
require_relative "stream_render"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-26s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 26], want.inspect[0, 26])
end

def ev(h) = JSON.generate(h) + "\n"
def assistant(*blocks) = ev(type: "assistant", message: {content: blocks})
def user_result(content) = ev(type: "user", message: {content: [{type: "tool_result", content: content}]})

RUN = [
  ev(type: "system", subtype: "init", model: "claude-opus-4"),
  ev(type: "system", subtype: "thinking_tokens", estimated_tokens: 42),
  ev(type: "rate_limit_event", rate_limit_info: {status: "allowed"}),
  assistant({type: "thinking", thinking: "a great deal of private working"}),
  assistant({type: "tool_use", name: "Bash",
             input: {command: "bundle exec rspec spec/prog/vnet/gcp", description: "run the specs"}}),
  user_result("379 examples, 0 failures\n"),
  assistant({type: "text", text: "Now I will write the review."}),
  ev(type: "result", subtype: "success", is_error: false, duration_ms: 1_380_000,
     num_turns: 27, result: "## Findings\n\nOne real bug.\n")
].join

out = StreamRender.all(RUN)

puts "-- what a person watching sees --"
check("the command it ran", out.include?("▸ Bash bundle exec rspec spec/prog/vnet/gcp"), true)
check("and what came back", out.include?("    379 examples, 0 failures"), true)
check("the model it is using", out.include?("claude-opus-4"), true)
check("how long it took", out.include?("finished in 1380s"), true)
check("and how many turns", out.include?("27 turns"), true)

puts "-- what it leaves out --"
check("not the private working", out.include?("private working"), false)
check("not the token counters", out.include?("thinking_tokens"), false)
check("nor the rate limit chatter", out.include?("rate_limit"), false)
# The review arrives whole in the result event, so printing prose as well put
# the same ten kilobytes on the page twice.
check("not interim prose", out.include?("Now I will write the review"), false)

puts "-- the review is separated from the trace --"
trace, review = out.split("#{StreamRender::MARKER}\n", 2)
check("the review is behind the marker", review, "## Findings\n\nOne real bug.\n")
check("and the trace holds no findings", trace.include?("One real bug"), false)

puts "-- it survives being read in pieces --"
# The stream cuts wherever the reader got to, which is rarely a line boundary.
[1, 7, 64, 1000].each do |size|
  cursor = StreamRender::Cursor.new
  piecemeal = +""
  RUN.each_char.each_slice(size) { |chunk| piecemeal << cursor.push(chunk.join) }
  piecemeal << cursor.finish
  check("read #{size} bytes at a time", piecemeal, out)
end

puts "-- and being fed things that are not events --"
check("bay's own lines pass through",
      StreamRender.all("⚙️  extension command: review\n").include?("extension command"), true)
check("a broken line is kept, not dropped",
      StreamRender.all("{not json at all\n").include?("not json at all"), true)
check("an empty log renders empty", StreamRender.all(""), "")
check("a half written line waits for the rest",
      StreamRender::Cursor.new.push('{"type":"result","result":"x"'), "")

puts "-- a failed run says so --"
bad = StreamRender.all(ev(type: "result", subtype: "error", is_error: true,
                          duration_ms: 5000, num_turns: 1, result: "it broke"))
check("it is reported as a failure", bad.include?("failed after 5s"), true)

puts "-- output is bounded, because a review makes hundreds of calls --"
long = StreamRender.all(user_result((1..100).map { |i| "line #{i}" }.join("\n")))
check("only the first few lines are shown", long.lines.size <= StreamRender::RESULT_LINES + 1, true)
check("and it says how many were dropped", long.include?("more lines"), true)
wide = StreamRender.all(assistant({type: "tool_use", name: "Bash", input: {command: "x" * 5000}}))
check("a huge command is cut", wide.length < 400, true)

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
