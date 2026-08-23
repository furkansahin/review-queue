#!/usr/bin/env ruby
# Transcript tests:  bundle exec ruby test_transcript.rb
require "json"
require_relative "stream_render"
require_relative "transcript"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-54s got=%-28s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 28], want.inspect[0, 28])
end

def ev(h) = JSON.generate(h) + "\n"
def tool(cmd) = ev(type: "assistant", message: {content: [{type: "tool_use", name: "Bash", input: {command: cmd}}]})
def result(text) = ev(type: "result", subtype: "success", is_error: false, duration_ms: 9000, num_turns: 3, result: text)

# A box that ran a review and then answered a follow-up, as the log holds it.
RAW = [
  "⚙️  extension command: review\n",
  "#{StreamRender::RUN_MARK}\n",
  tool("git diff origin/main"),
  result("## Findings\n\nOne real bug.\n"),
  "#{StreamRender::EXIT_MARK}0\n",
  "#{StreamRender::RUN_MARK}\n",
  "\n#{StreamRender::ASKED}\nlist the repair items\n\n",
  tool("bundle exec rspec spec/thing_spec.rb"),
  result("# Repair items\n\n1. Do the thing.\n"),
  "#{StreamRender::EXIT_MARK}0\n"
].join

SECTIONS = Transcript.sections(StreamRender.all(RAW))

puts "-- one panel per stage, in order --"
check("the stages", SECTIONS.map(&:kind), %i[build trace answer question trace answer])
check("named for what they hold",
      SECTIONS.map(&:title),
      ["preparing the box", "what the review ran", "the review", "you asked", "what it ran", "the answer"])

puts "-- each holds only its own --"
build, first_trace, review, question, ask_trace, answer = SECTIONS
check("bay's lines are the build panel", build.text.include?("extension command"), true)
check("and no tool calls are in it", build.text.include?("▸"), false)
check("the review's trace holds its command", first_trace.text.include?("git diff origin/main"), true)
check("the review is the review", review.text.strip, "## Findings\n\nOne real bug.")
check("the question is the question", question.text, "list the repair items")
check("the follow-up's trace is its own", ask_trace.text.include?("rspec spec/thing_spec.rb"), true)
check("and does not repeat the review's", ask_trace.text.include?("git diff"), false)
check("the answer is the answer", answer.text.strip, "# Repair items\n\n1. Do the thing.")

puts "-- the newest answer is the one left open --"
check("only one is open", SECTIONS.count(&:open), 1)
check("and it is the last answer", SECTIONS.rindex(&:open), SECTIONS.length - 1)
check("so the review closes when a follow-up answers", review.open, false)

puts "-- a review on its own --"
only = Transcript.sections(StreamRender.all([
  "⚙️  extension command: review\n", "#{StreamRender::RUN_MARK}\n",
  tool("ls"), result("all good\n"), "#{StreamRender::EXIT_MARK}0\n"
].join))
check("three panels", only.map(&:kind), %i[build trace answer])
check("and the review is open", only.last.open, true)

puts "-- a run still going has no answer yet --"
partial = Transcript.sections(StreamRender.all([
  "#{StreamRender::RUN_MARK}\n", tool("bundle exec rspec")
].join))
check("the trace is there", partial.map(&:kind), %i[trace])
check("and nothing claims to be an answer", partial.any? { |s| s.kind == :answer }, false)

puts "-- nothing at all --"
check("no sections", Transcript.sections(""), [])
check("nor for whitespace", Transcript.sections("   \n"), [])

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
