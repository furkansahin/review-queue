#!/usr/bin/env ruby
# Diff parsing and colouring:  bundle exec ruby test_diff_view.rb
require_relative "diff_view"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-58s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

DIFF = <<~'DIFF'
  diff --git a/prog/thing.rb b/prog/thing.rb
  index 1111111..2222222 100644
  --- a/prog/thing.rb
  +++ b/prog/thing.rb
  @@ -10,6 +10,7 @@ class Thing
     def run
  -    old_call
  +    new_call
  +    # a <script>alert(1)</script> & more
       msg = "a string
     that spans lines"
  --- this removed line starts with two dashes
     end
  diff --git a/lib/new.rb b/lib/new.rb
  new file mode 100644
  index 0000000..3333333
  --- /dev/null
  +++ b/lib/new.rb
  @@ -0,0 +1,2 @@
  +module New
  +end
  \ No newline at end of file
  diff --git a/lib/gone.rb b/lib/gone.rb
  deleted file mode 100644
  index 4444444..0000000
  --- a/lib/gone.rb
  +++ /dev/null
  @@ -1 +0,0 @@
  -x = 1
  diff --git a/old/name.rb b/new/name.rb
  similarity index 90%
  rename from old/name.rb
  rename to new/name.rb
  diff --git a/logo.png b/logo.png
  index 5555555..6666666 100644
  Binary files a/logo.png and b/logo.png differ
DIFF

files = DiffView.parse(DIFF)
by = files.to_h { |f| [f.path, f] }
puts "-- files --"
check("five files", files.size, 5)
check("a modified one", by["prog/thing.rb"].status, :modified)
check("a new one", [by["lib/new.rb"].status, by["lib/new.rb"].old_path], [:added, nil])
check("a deleted one, known by its old path", [by["lib/gone.rb"].status, by["lib/gone.rb"].new_path], [:deleted, nil])
check("a rename, both names", [by["new/name.rb"].status, by["new/name.rb"].old_path], [:renamed, "old/name.rb"])
check("a binary one", by["logo.png"].binary, true)

puts "-- lines --"
t = by["prog/thing.rb"]
lines = t.hunks.first.lines
check("counted: +2 -2", [t.additions, t.deletions], [2, 2])
check("context is numbered on both sides", [lines[0].kind, lines[0].old_no, lines[0].new_no], [:ctx, 10, 10])
check("a removed line has only its old number", [lines[1].kind, lines[1].old_no, lines[1].new_no], [:del, 11, nil])
check("an added line only its new one", [lines[2].kind, lines[2].old_no, lines[2].new_no], [:add, nil, 11])
removed_dashes = lines.find { |l| l.text.start_with?("-- this removed") }
check("a removed '--' line is a line, not a header", removed_dashes && removed_dashes.kind, :del)
check("the file's paths were not clobbered by it", t.old_path, "prog/thing.rb")
check("no-newline is a note, not code", by["lib/new.rb"].hunks.first.lines.last.kind, :note)

puts "-- colour, and nothing unescaped --"
html = lines.map(&:html).compact.join("\n")
check("Ruby is coloured", html.include?("<span class="), true)
check("code is escaped", html.include?("&lt;script&gt;alert(1)&lt;/script&gt;"), true)
check("nothing from the code runs", html.include?("<script>"), false)
check("an ampersand too", html.include?("&amp; more"), true)
string_line = lines.find { |l| l.text.include?("that spans lines") }
check("a string over two lines is still a string on the second", string_line.html.to_s.match?(/class="s/), true)
check("every coloured line closes what it opens", lines.all? { |l| l.html.nil? || l.html.scan("<span").size == l.html.scan("</span>").size }, true)

puts "-- a comment finds its line again --"
check("by new line number", DiffView.find(files, "prog/thing.rb", "new", 11).text, "    new_call")
check("by old line number, for a removed line", DiffView.find(files, "prog/thing.rb", "old", 11).text, "    old_call")
check("a removed line is not found as new", DiffView.find(files, "prog/thing.rb", "new", 99), nil)
check("nor a file that is not there", DiffView.find(files, "nope.rb", "new", 1), nil)

puts "-- the rest --"
check("an empty diff is no files", DiffView.parse(""), [])
big = "diff --git a/x.rb b/x.rb\n--- a/x.rb\n+++ b/x.rb\n@@ -1,0 +1,4000 @@\n" + ("+x = 1\n" * 4000)
check("a huge file is parsed but not coloured", DiffView.parse(big).first.hunks.first.lines.first.html, nil)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
