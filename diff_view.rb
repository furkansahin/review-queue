require "rouge"
require "cgi"

# A unified diff as files, hunks and numbered lines, coloured, for the changes
# page -- and the way back from "path, side, line number" to the line's text,
# so a review comment can quote the code it is about.
module DiffView
  module_function

  # kind is :ctx, :add, :del, or :note (git's "\ No newline at end of file").
  Line = Struct.new(:kind, :old_no, :new_no, :text, :html, keyword_init: true)
  Hunk = Struct.new(:header, :lines, keyword_init: true)
  FileDiff = Struct.new(:old_path, :new_path, :status, :hunks, :additions, :deletions, :binary,
                        keyword_init: true) do
    def path = new_path || old_path
  end

  # Past this many lines a file is parsed but not coloured: lexing is the slow
  # part, and a generated file that big is not read line by line anyway.
  HIGHLIGHT_MAX_LINES = 3000

  def parse(text, highlight: true)
    files = []
    file = hunk = nil
    old_no = new_no = 0
    text.to_s.each_line(chomp: true) do |line|
      # Neither can be content: every content line starts with " ", "+", "-"
      # or "\", so these two are always structure.
      if line.start_with?("diff --git ")
        file = FileDiff.new(status: :modified, hunks: [], additions: 0, deletions: 0, binary: false)
        if (m = line.match(%r{\Adiff --git a/(.+) b/(.+)\z}))
          file.old_path, file.new_path = m[1], m[2]
        end
        files << file
        hunk = nil
        next
      end
      next unless file
      if (m = line.match(/\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/))
        old_no, new_no = m[1].to_i, m[2].to_i
        hunk = Hunk.new(header: line, lines: [])
        file.hunks << hunk
        next
      end
      if hunk.nil?
        header(file, line)
        next
      end
      case line[0]
      when " ", nil
        hunk.lines << Line.new(kind: :ctx, old_no: old_no, new_no: new_no, text: line[1..].to_s)
        old_no += 1
        new_no += 1
      when "+"
        hunk.lines << Line.new(kind: :add, new_no: new_no, text: line[1..])
        new_no += 1
        file.additions += 1
      when "-"
        hunk.lines << Line.new(kind: :del, old_no: old_no, text: line[1..])
        old_no += 1
        file.deletions += 1
      when "\\"
        hunk.lines << Line.new(kind: :note, text: line[1..].strip)
      end
    end
    files.each { |f| colour!(f) } if highlight
    files
  end

  # The lines between "diff --git" and the first hunk. ---/+++ are only read
  # here: inside a hunk a line starting "---" is a removed "--" line.
  def header(file, line)
    case line
    when /\Anew file mode/ then file.status = :added
    when /\Adeleted file mode/ then file.status = :deleted
    when /\Arename from (.+)\z/ then file.old_path = $1; file.status = :renamed
    when /\Arename to (.+)\z/ then file.new_path = $1; file.status = :renamed
    when /\ABinary files / then file.binary = true
    when %r{\A--- /dev/null\z} then file.old_path = nil
    when %r{\A\+\+\+ /dev/null\z} then file.new_path = nil
    when %r{\A--- a/(.+)\z} then file.old_path = $1
    when %r{\A\+\+\+ b/(.+)\z} then file.new_path = $1
    end
  end

  # Each hunk is coloured as two runs of text -- what was there, what is there
  # now -- rather than line by line, so a string or a block that spans lines
  # is read as one.
  def colour!(file)
    return if file.hunks.sum { |h| h.lines.size } > HIGHLIGHT_MAX_LINES
    lexer = begin
      Rouge::Lexer.guess_by_filename(file.path.to_s)
    rescue StandardError
      Rouge::Lexers::PlainText
    end
    file.hunks.each do |h|
      before = h.lines.select { |l| l.kind == :ctx || l.kind == :del }
      after = h.lines.select { |l| l.kind == :ctx || l.kind == :add }
      lines_html(lexer, before.map(&:text)).each_with_index { |html, i| before[i].html = html if before[i].kind == :del }
      lines_html(lexer, after.map(&:text)).each_with_index { |html, i| after[i].html = html }
    end
  end

  # One HTML string per input line. Tokens that span lines are cut at each
  # newline, so no span is ever open across two rows.
  def lines_html(lexer, texts)
    return [] if texts.empty?
    out = [+""]
    lexer.lex(texts.join("\n")).each do |token, value|
      cls = token.shortname
      value.split("\n", -1).each_with_index do |part, i|
        out << +"" if i.positive?
        next if part.empty?
        esc = CGI.escapeHTML(part)
        out[-1] << (cls.to_s.empty? ? esc : %(<span class="#{cls}">#{esc}</span>))
      end
    end
    out.fill(+"", out.size...texts.size).first(texts.size)
  rescue StandardError
    texts.map { |t| CGI.escapeHTML(t) }
  end

  # The line a comment points at, or nil if the diff no longer has it.
  def find(files, path, side, number)
    file = files.find { |f| f.path == path }
    return nil unless file
    key = side == "old" ? :old_no : :new_no
    file.hunks.each do |h|
      h.lines.each do |l|
        next if l.kind == :note
        next if side == "old" ? l.kind == :add : l.kind == :del
        return l if l.public_send(key) == number
      end
    end
    nil
  end
end
