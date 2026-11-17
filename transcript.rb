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

  BOUNDARY = /^#{Regexp.escape(StreamRender::RUN)}\s*$\n?/

  # In order, with two answers left open: the first, the review that the
  # questions after it refer back to, and the newest, the one just asked for.
  # Everything else is there to open when you want it.
  #
  # review is the first answer as it was kept when it finished (Jobs.finish).
  # The text here is the rendered end of the log, and a review's own run is
  # long enough that a follow-up or two pushes it out of that window; then
  # the kept one is put back at the top.
  def sections(text, review: nil)
    parts = text.to_s.split(BOUNDARY)
    # Whatever bay said before the first run started -- the worktree, the
    # container, the checkout. That is the part worth folding away once the
    # review itself begins.
    head = parts.shift.to_s
    out = []
    if parts.empty?
      # A log from before run boundaries were written. It is one run, and none
      # of it is a build: putting it in both panels showed everything twice.
      out.concat(run_sections(head, true, boundaried: false))
    elsif head.include?("#{StreamRender::MARKER}\n")
      # The window opens partway into the review's run, past its boundary:
      # this is the end of the review, answer and all. Shown as bay preparing
      # the box, it was the review in raw markdown under the wrong name.
      out.concat(run_sections(head, true, boundaried: true))
      parts.each { |run| out.concat(run_sections(run, false, boundaried: true)) }
    elsif head.each_line.any? { |l| l.start_with?("▸") }
      # Partway into the review's trace: the rest of it, with its answer, is
      # cut off. Bay never runs a tool.
      out << Section.new(kind: :trace, title: "what the review ran", text: head)
      parts.each { |run| out.concat(run_sections(run, false, boundaried: true)) }
    else
      out << Section.new(kind: :build, title: "preparing the box", text: head)
      parts.each_with_index { |run, i| out.concat(run_sections(run, i.zero?, boundaried: true)) }
    end
    out.reject!(&:empty?)
    out.each { |s| cap!(s) unless s.kind == :answer || s.kind == :question }
    if review.to_s.strip != "" && out.none? { |s| s.kind == :answer && s.text.strip == review.strip }
      out.unshift(Section.new(kind: :answer, title: "the review", text: review))
    end
    answers = out.each_index.select { |i| out[i].kind == :answer }
    out.each_with_index { |s, i| s.open = (i == answers.first || i == answers.last) }
    out
  end

  # The first answer in a rendered log, which is the review itself; nil when
  # there is none yet.
  def first_answer(text)
    found = sections(text).find { |s| s.kind == :answer }
    found && !found.text.strip.empty? ? found.text : nil
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
