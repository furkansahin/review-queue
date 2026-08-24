require "cgi"
require "rouge"

# The small part of markdown a review actually uses, rendered to HTML.
#
# A review is headings, fenced code, inline code, bold and lists. It arrived as
# one wall of monospaced text, so a finding's file:line, its code and its prose
# all looked the same. This gives them different weight.
#
# Everything is escaped before anything is added. The text comes from a model
# reading a pull request, which means it contains whatever that pull request
# contains -- a review of a change to an HTML template is not an unusual thing
# to be reading, and neither is a finding that quotes a script tag.
module Markdown
  extend self

  FENCE = /\A\s*```+\s*([\w+-]*)\s*\z/
  # \Z, not \z: these are whole lines, so they carry their newline.
  HEADING = /\A(\#{1,4})\s+(.*)\Z/

  def render(text)
    out = +""
    lines = text.to_s.lines
    i = 0
    while i < lines.length
      line = lines[i]
      if (m = FENCE.match(line))
        body, i = take_fence(lines, i + 1)
        out << code_block(body, m[1])
        next
      end
      if (m = HEADING.match(line))
        level = m[1].length + 2
        out << "<h#{level}>#{inline(m[2])}</h#{level}>\n"
        i += 1
        next
      end
      if line.match?(/\A\s*(?:[-*+]|\d+\.)\s+/)
        items, i = take_list(lines, i)
        out << "<ul>\n" << items.map { |t| "<li>#{inline(t)}</li>\n" }.join << "</ul>\n"
        next
      end
      if line.strip.empty?
        i += 1
        next
      end
      para, i = take_paragraph(lines, i)
      out << "<p>#{inline(para)}</p>\n"
    end
    out
  end

  private

  # An unclosed fence runs to the end. A review is sometimes cut short, and the
  # rest of it should still be readable rather than vanishing into a code block
  # that never ends.
  def take_fence(lines, i)
    body = +""
    while i < lines.length && !FENCE.match?(lines[i])
      body << lines[i]
      i += 1
    end
    [body, i + 1]
  end

  def take_list(lines, i)
    items = []
    while i < lines.length && (m = lines[i].match(/\A\s*(?:[-*+]|\d+\.)\s+(.*)\z/m))
      items << m[1].strip
      i += 1
    end
    [items, i]
  end

  def take_paragraph(lines, i)
    para = +""
    while i < lines.length && !lines[i].strip.empty? &&
        !FENCE.match?(lines[i]) && !HEADING.match?(lines[i]) &&
        !lines[i].match?(/\A\s*(?:[-*+]|\d+\.)\s+/)
      para << lines[i]
      i += 1
    end
    [para.strip, i]
  end

  # Rouge picks the lexer; an unknown or missing language falls back to plain
  # text rather than guessing, because a wrong guess colours things as if they
  # meant something.
  def code_block(body, language)
    lexer = language.to_s.empty? ? nil : Rouge::Lexer.find(language.to_s.downcase)
    return "<pre class=\"code\">#{CGI.escapeHTML(body)}</pre>\n" unless lexer
    formatter = Rouge::Formatters::HTML.new
    "<pre class=\"code\"><code>#{formatter.format(lexer.lex(body))}</code></pre>\n"
  end

  # Escape first, then add the few things a review leans on. Doing it the other
  # way round is how a review of an HTML template becomes a script tag on this
  # page.
  def inline(text)
    safe = CGI.escapeHTML(text.to_s.strip)
    safe = safe.gsub(/`([^`]+)`/) { "<code>#{Regexp.last_match(1)}</code>" }
    safe = safe.gsub(/\*\*([^*]+)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }
    # Single asterisks, after the double ones, so **bold** is not eaten a star
    # at a time. A review leans on these for the word that carries the point.
    safe = safe.gsub(/(?<![\w*])\*([^*\n]+)\*(?![\w*])/) { "<em>#{Regexp.last_match(1)}</em>" }
    safe.gsub("\n", "<br />\n")
  end
end
