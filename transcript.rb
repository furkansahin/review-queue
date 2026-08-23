require_relative "stream_render"

# Cuts a rendered run into the panels the sessions page shows.
#
# A box is used more than once: the review, then a follow-up, then another. All
# of it lands in one log, which the page used to show as two panels -- one
# labelled "build log from bay", which by then held the review's tool trace and
# no build at all, and one holding whichever answer happened to be last.
#
# The renderer leaves boundaries behind. This turns them into sections, so each
# stage opens and closes on its own, and the answer you are reading sits next
# to the question that asked for it.
module Transcript
  extend self

  # A trace runs to hundreds of lines and this page lists fifty jobs, so what
  # a panel shows is capped. The newest lines are the ones worth keeping: a
  # trace is read from the end.
  MAX_LINES = Integer(ENV.fetch("RQ_PANEL_LINES", "200"))

  Section = Struct.new(:kind, :title, :text, :open, :dropped, keyword_init: true) do
    def empty? = text.to_s.strip.empty?
  end

  # In order, and only the newest answer left open: that is the one worth
  # reading, and everything else is there to open when you want it.
  def sections(text)
    parts = text.to_s.split(/^#{Regexp.escape(StreamRender::RUN)}\s*$\n?/)
    # Whatever bay said before the first run started -- the worktree, the
    # container, the checkout. That is the part worth folding away once the
    # review itself begins.
    head = parts.shift.to_s
    out = []
    if parts.empty?
      # A log from before run boundaries were written. It is one run, and none
      # of it is a build: putting it in both panels showed everything twice.
      out.concat(run_sections(head, true, boundaried: false))
    else
      out << Section.new(kind: :build, title: "preparing the box", text: head)
      parts.each_with_index { |run, i| out.concat(run_sections(run, i.zero?, boundaried: true)) }
    end
    out.reject!(&:empty?)
    out.each { |s| cap!(s) unless s.kind == :answer || s.kind == :question }
    last_answer = out.rindex { |s| s.kind == :answer }
    out.each_with_index { |s, i| s.open = (i == last_answer) }
    out
  end

  private

  # An answer is never cut: it is the thing being read. A trace is.
  def cap!(section)
    lines = section.text.lines
    return if lines.size <= MAX_LINES
    section.dropped = lines.size - MAX_LINES
    section.text = lines.last(MAX_LINES).join
  end

  def run_sections(run, first, boundaried:)
    trace, answer = run.split("#{StreamRender::MARKER}\n", 2)
    # A log with no marker and no run boundary predates both. All of it is the
    # review, which is how the page has always read one -- and reading it as a
    # trace instead meant capping it from the end and losing its opening.
    return [Section.new(kind: :answer, title: "the review", text: run)] if answer.nil? && !boundaried
    trace = trace.to_s
    question = nil

    # A follow-up writes the question into its run before it starts, so the
    # question sits at the top of that run's trace.
    if (i = trace.index("#{StreamRender::ASKED}\n"))
      before = trace[0...i]
      question, tail = split_question(trace[(i + StreamRender::ASKED.length + 1)..].to_s)
      trace = before + tail
    end

    [
      (question ? Section.new(kind: :question, title: "you asked", text: question) : nil),
      Section.new(kind: :trace, title: first ? "what the review ran" : "what it ran", text: trace),
      Section.new(kind: :answer, title: first ? "the review" : "the answer", text: answer.to_s)
    ].compact
  end

  # The question runs until the run does something. A blank line would have
  # been the natural separator, but rendering drops blank lines, so the first
  # step of the run is the boundary instead.
  def split_question(rest)
    lines = rest.lines
    stop = lines.index { |l| l.start_with?("▸") }
    return [rest.strip, ""] unless stop
    [lines[0...stop].join.strip, lines[stop..].join]
  end
end
