require "json"

# Turns claude's stream-json events into something worth watching.
#
# `claude -p` writes its whole answer in one go, so a review showed nothing for
# twenty minutes and then everything at once -- the live log sat at 34 bytes
# while the box ran 379 specs. With --output-format stream-json it emits an
# event per step instead: which command it ran, what came back, what it
# concluded.
#
# The raw events are what gets stored, both here and in the box, so the
# rendering can be changed later without re-running a review. This only decides
# how they read.
module StreamRender
  extend self

  # Everything before this is the trace, which the sessions page keeps in a
  # collapsed panel. Everything after is the review itself.
  MARKER = "== review"

  # A tool call's arguments and a tool's output are both unbounded, and a
  # review makes hundreds of them. These caps are what keep a twenty minute
  # trace readable, and the page under its size budget.
  INPUT_CHARS = 200
  RESULT_LINES = 6
  RESULT_CHARS = 400

  # Feed bytes as they arrive. Returns readable text for the complete lines it
  # has, and keeps a partial line for next time -- the stream cuts wherever the
  # reader happened to be, which is rarely a line boundary.
  class Cursor
    def initialize
      @buffer = +""
    end

    def push(bytes)
      @buffer << bytes.to_s
      out = +""
      while (i = @buffer.index("\n"))
        line = @buffer.slice!(0, i + 1)
        piece = StreamRender.line(line)
        out << piece if piece
      end
      out
    end

    # Whatever is left when the run ends, which may be a line with no newline.
    def finish
      rest = @buffer
      @buffer = +""
      rest.strip.empty? ? "" : StreamRender.line(rest).to_s
    end
  end

  # The whole of a stored run, rendered at once.
  def all(text)
    cursor = Cursor.new
    cursor.push(text.to_s) + cursor.finish
  end

  def line(raw)
    text = raw.to_s.strip
    return nil if text.empty?
    # bay prints its own lines around the command it runs. They are already
    # readable, so they pass through untouched.
    return raw unless text.start_with?("{")
    event = begin
      JSON.parse(text)
    rescue JSON::ParserError
      return raw
    end
    render(event)
  end

  def render(event)
    case event["type"]
    when "assistant" then blocks(event).map { |b| assistant_block(b) }.compact.join
    when "user" then blocks(event).map { |b| user_block(b) }.compact.join
    when "result" then final(event)
    when "system" then event["subtype"] == "init" ? "▸ #{event["model"]}\n" : nil
    end
  end

  def blocks(event)
    content = event.dig("message", "content")
    content.is_a?(Array) ? content.select { |b| b.is_a?(Hash) } : []
  end

  def assistant_block(block)
    case block["type"]
    # Thinking is the model's own working, and there is a great deal of it.
    # The trace says work is happening; it does not print the working.
    when "thinking" then nil
    # Nor prose. The trace is a record of what the review did -- which command,
    # what came back. What it concluded is the review, and that arrives whole
    # in the result event below. Printing both put the same ten kilobytes on
    # the page twice.
    when "text" then nil
    when "tool_use" then "▸ #{block["name"]} #{tool_input(block)}\n"
    end
  end

  def user_block(block)
    return nil unless block["type"] == "tool_result"
    body = flatten(block["content"])
    return nil if body.strip.empty?
    lines = body.lines
    shown = lines.first(RESULT_LINES).map { |l| "    #{l.chomp[0, RESULT_CHARS]}\n" }.join
    shown += "    … #{lines.size - RESULT_LINES} more lines\n" if lines.size > RESULT_LINES
    shown
  end

  # Every tool has its own idea of what matters. Name the thing being acted on,
  # not the whole argument object.
  def tool_input(block)
    input = block["input"]
    return "" unless input.is_a?(Hash)
    value = input["command"] || input["file_path"] || input["pattern"] || input["path"] ||
      input["description"] || JSON.generate(input)
    squeeze(value.to_s)[0, INPUT_CHARS]
  end

  def final(event)
    body = squeeze(event["result"].to_s)
    took = event["duration_ms"].to_i / 1000
    head = event["is_error"] ? "▸ failed after #{took}s" : "▸ finished in #{took}s"
    turns = event["num_turns"]
    head += ", #{turns} turns" if turns
    return "#{head}\n" if body.empty?
    "#{head}\n\n#{MARKER}\n#{body}\n"
  end

  def flatten(content)
    case content
    when String then content
    when Array
      content.filter_map { |b| b.is_a?(Hash) ? b["text"] : b.to_s }.join("\n")
    else content.to_s
    end
  end

  def squeeze(value) = value.to_s.gsub(/\r\n?/, "\n").strip
end
