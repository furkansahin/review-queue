#!/usr/bin/env ruby
# A review from the changes page, as the box reads it:  bundle exec ruby test_review_note.rb
require_relative "review_note"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

BRANCH = <<~DIFF
  diff --git a/prog/thing.rb b/prog/thing.rb
  --- a/prog/thing.rb
  +++ b/prog/thing.rb
  @@ -1,3 +1,3 @@
   class Thing
  -  def old_name = 1
  +  def new_name = 2
   end
DIFF
COMMIT = <<~DIFF
  diff --git a/db/migrate/001_limit.rb b/db/migrate/001_limit.rb
  new file mode 100644
  --- /dev/null
  +++ b/db/migrate/001_limit.rb
  @@ -0,0 +1,2 @@
  +Sequel.migration do
  +end
DIFF
DIFF_DATA = {head: "abcdef1234567890", branch: BRANCH,
             commits: [{sha: "c0ffee1234567890", subject: "Add the limit column", body: "", patch: COMMIT}]}

def c(**kw) = {"view" => "branch", "side" => "new"}.merge(kw.transform_keys(&:to_s))

res = ReviewNote.compose(DIFF_DATA, [
  c(path: "prog/thing.rb", line: 2, text: "  def new_name = 2", body: "Name this after what it returns."),
  c(path: "prog/thing.rb", side: "old", line: 2, text: "  def old_name = 1", body: "Was anything calling this?"),
  c(view: "c0ffee1234567890", path: "db/migrate/001_limit.rb", line: 1, text: "Sequel.migration do", body: "Needs a down.\nOr say why not.")
], "Split the rename into its own commit.", head: "abcdef1234567890")
text = res[:text]
puts "-- what the box reads --"
check("it composes", res[:error], nil)
check("and counts the comments", res[:count], 3)
check("says what it is a review of", text.include?("as it stood at abcdef1234"), true)
check("asks for every comment to be addressed", text.include?("Address every comment"), true)
check("and for the skills to be checked again", text.include?("check the branch against your skills again"), true)
check("a line comment names file and line", text.include?("1. `prog/thing.rb` line 2"), true)
check("and quotes the code", text.include?("> def new_name = 2"), true)
check("a removed line says so", text.include?("2. `prog/thing.rb`, removed line 2"), true)
check("and quotes what was removed", text.include?("> def old_name = 1"), true)
check("a comment on a commit names the commit", text.include?(%(in commit c0ffee1234 "Add the limit column")), true)
check("a comment over lines keeps them together", text.include?("Needs a down.\n   Or say why not."), true)
check("the overall note comes last", text.end_with?("Overall:\nSplit the rename into its own commit."), true)
check("nothing is marked as moved", text.include?("no longer there"), false)

puts "-- a line that has moved since --"
moved = ReviewNote.compose(DIFF_DATA, [c(path: "prog/thing.rb", line: 2, text: "  def something_else", body: "x")], "")
check("is quoted as the person saw it", moved[:text].include?("> def something_else"), true)
check("and said to have moved", moved[:text].include?("no longer there as quoted"), true)
gone = ReviewNote.compose(DIFF_DATA, [c(path: "nope.rb", line: 9, text: "whatever", body: "x")], "")
check("a file that is gone too", gone[:text].include?("no longer there as quoted"), true)

puts "-- what is refused --"
check("nothing to send", ReviewNote.compose(DIFF_DATA, [], "  ")[:error].to_s.include?("write a comment"), true)
check("an empty comment counts as none", ReviewNote.compose(DIFF_DATA, [c(path: "a", line: 1, text: "", body: " ")], "")[:error].to_s.include?("write a comment"), true)
check("an overall note alone is enough", ReviewNote.compose(DIFF_DATA, [], "Looks fine; tighten the specs.")[:count], 0)
check("no diff yet", ReviewNote.compose(nil, [], "x")[:error].to_s.include?("no diff"), true)
check("comments that are not a list", ReviewNote.compose(DIFF_DATA, "nope", "x")[:error].to_s.include?("did not arrive whole"), true)
many = Array.new(101) { |i| c(path: "a", line: i, text: "", body: "b") }
check("more than a hundred", ReviewNote.compose(DIFF_DATA, many, "")[:error].to_s.include?("more than 100"), true)
check("a comment that is too long", ReviewNote.compose(DIFF_DATA, [c(path: "a", line: 1, text: "", body: "x" * 4001)], "")[:error].to_s.include?("over 4000"), true)
check("an overall note that is too long", ReviewNote.compose(DIFF_DATA, [], "x" * 8001)[:error].to_s.include?("over 8000"), true)
big = Array.new(60) { |i| c(path: "a", line: i, text: "", body: "y" * 3900) }
check("a review too long to send at once", ReviewNote.compose(DIFF_DATA, big, "")[:error].to_s.include?("too long"), true)
check("a line number that is not one is not a crash",
      ReviewNote.compose(DIFF_DATA, [c(path: "a", line: "1; rm -rf /", text: "", body: "b")], "")[:count], 1)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
