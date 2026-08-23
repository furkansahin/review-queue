#!/usr/bin/env ruby
# Review formatting tests:  bundle exec ruby test_markdown.rb
require_relative "markdown"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-56s got=%-24s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0, 24], want.inspect[0, 24])
end

puts "-- nothing a review contains may become markup --"
# The text is a model reading a pull request, so it holds whatever that pull
# request holds. A review of a change to an HTML template is ordinary.
danger = Markdown.render("<script>alert(1)</script> and <img onerror=x>\n")
check("a script tag is text", danger.include?("<script>"), false)
check("and is still readable", danger.include?("&lt;script&gt;"), true)
check("an attribute cannot escape", danger.include?("onerror=x>"), false)
check("inside a fence too",
      Markdown.render("```\n<script>alert(1)</script>\n```\n").include?("<script>a"), false)
check("inside inline code too",
      Markdown.render("try `<script>` here\n").include?("<code>&lt;script&gt;</code>"), true)
check("a heading cannot carry markup",
      Markdown.render("## <b>bold</b>\n").include?("<b>bold</b>"), false)

puts "-- the shape a review is written in --"
out = Markdown.render(<<~MD)
  ## 1. The bug — `prog/vm/nexus.rb:34`

  It raises on an empty list. **This matters.**

  - first thing
  - second thing

  ```ruby
  def broken(list)
    list.reduce(:+)
  end
  ```
MD
check("headings become headings", out.include?("<h4>"), true)
check("the file reference is code", out.include?("<code>prog/vm/nexus.rb:34</code>"), true)
check("emphasis is kept", out.include?("<strong>This matters.</strong>"), true)
check("the list is a list", out.scan("<li>").size, 2)
check("the code block is a block", out.include?('<pre class="code">'), true)

puts "-- and the code in it is coloured --"
check("ruby is highlighted", out.include?("<span"), true)
check("the keyword is marked up", out.match?(/<span class="[^"]*">def<\/span>/), true)
check("the code itself is intact", out.include?("reduce"), true)

puts "-- languages it will meet --"
%w[bash sql diff json yaml].each do |lang|
  r = Markdown.render("```#{lang}\nselect 1;\n```\n")
  check("#{lang} is recognised", r.include?("<code>"), true)
end
plain = Markdown.render("```\njust text\n```\n")
check("no language means no guessing", plain.include?("<code>"), false)
check("but the text survives", plain.include?("just text"), true)
odd = Markdown.render("```wingdings\nx\n```\n")
check("an unknown language is not guessed at", odd.include?("<code>"), false)

puts "-- text that is cut short is still readable --"
cut = Markdown.render("before\n\n```ruby\ndef half\n")
check("an unclosed fence still closes", cut.scan("<pre").size, 1)
check("and what came before survives", cut.include?("before"), true)

puts "-- nothing at all --"
check("empty renders empty", Markdown.render(""), "")
check("whitespace renders empty", Markdown.render("   \n\n"), "")

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
