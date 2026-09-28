require "securerandom"

# The mark: a drop with a little water left at the bottom. The app is named
# after Jan Adriaanszoon Leeghwater, who drained the Beemster with windmills in
# 1612, and his name means "empty water" -- which is what it does to a review
# queue. On the pages the water is the queue: the share of it still waiting on
# you, so the drop empties as you get through it.
module Logo
  OUTLINE = "M32 5C32 5 13 26 13 40C13 50.5 21.5 59 32 59C42.5 59 51 50.5 51 40C51 26 32 5 32 5Z"

  # Where the surface sits, in the 64-unit box, for the drop to hold 0..100%
  # of its water -- by area, not height: the drop is wide at the bottom and
  # narrow at the top, so by height a queue one-tenth full would look nearly
  # empty. Worked out from the outline's own curves.
  LEVELS = begin
    bez = ->(c, t) { (0..1).map { |k| ((1 - t)**3 * c[0][k]) + (3 * (1 - t)**2 * t * c[1][k]) + (3 * (1 - t) * t**2 * c[2][k]) + (t**3 * c[3][k]) } }
    # The left half, tip to widest point to bottom; the right is its mirror.
    left = [[[32, 5], [32, 5], [13, 26], [13, 40]], [[13, 40], [13, 50.5], [21.5, 59], [32, 59]]]
      .flat_map { |c| (0..400).map { |i| bez.call(c, i / 400.0) } }.sort_by(&:last)
    width = lambda do |y|
      i = left.rindex { |(_, py)| py <= y } || 0
      (x0, y0), (x1, y1) = left[i], left[[i + 1, left.size - 1].min]
      2 * (32 - (y1 == y0 ? x0 : x0 + ((x1 - x0) * (y - y0) / (y1 - y0))))
    end
    ys = (0..1080).map { |i| 59 - (i * 0.05) }
    area = [0.0]
    ys.each_cons(2) { |a, b| area << (area.last + ((width.call(a) + width.call(b)) / 2 * (a - b))) }
    levels = (0..100).map { |p| ys[area.index { |v| v >= area.last * p / 100.0 } || ys.size - 1].round(1) }
    # Clear of the outline at both ends, wave and all: nothing at 0%, no dry
    # corner at the tip at 100%.
    levels[0] = 62.0
    levels[100] = 1.0
    levels
  end.freeze

  # The mark as it was drawn, and as the PNG and the sign-in page show it.
  DEFAULT = 25
  # The least water drawn while anything is waiting: below this the water is
  # a fleck at 64px and nothing at all in a tab, and one pull request in three
  # hundred would look like a clear queue. The count itself stays exact.
  MIN_SHOWN = 6

  module_function

  def level(pct)
    pct = (pct || DEFAULT).to_i.clamp(0, 100)
    LEVELS[pct.positive? ? [pct, MIN_SHOWN].max : 0]
  end

  # A wave across at the surface, and down well past the bottom, so moving it
  # up while it drains never shows a gap beneath it.
  def water(pct)
    "M-4 #{level(pct)}q4 -3.2 8 0#{"t8 0" * 9}V130H-4Z"
  end

  # For a page: the outline takes the text colour and the water the accent,
  # so it follows the page into dark mode. pct is how full it is, nil for the
  # mark as drawn. Given from, the water starts at that level and runs to its
  # own -- drains, usually -- unless the viewer asked for less motion.
  def svg(size, fill: nil, from: nil)
    size = Integer(size)
    id = "lw#{SecureRandom.hex(4)}"
    move = ""
    if from && fill && from != fill
      dy = (level(from) - level(fill)).round(1)
      move = "<style>@media (prefers-reduced-motion:no-preference){##{id}w{animation:#{id}a 1.6s cubic-bezier(.3,.7,.2,1) .3s both}}" \
             "@keyframes #{id}a{from{transform:translateY(#{dy}px)}}</style>"
    end
    %(<svg width="#{size}" height="#{size}" viewBox="0 0 64 64" aria-hidden="true" focusable="false" ) +
      %(style="display: block; flex: none;">#{move}<clipPath id="#{id}c"><path d="#{OUTLINE}"/></clipPath>) +
      %(<g clip-path="url(##{id}c)"><g id="#{id}w"><path d="#{water(fill)}" fill="var(--accent)"/></g></g>) +
      %(<path d="#{OUTLINE}" fill="none" stroke="currentColor" stroke-width="4.5" stroke-linejoin="round"/></svg>)
  end

  # The tab icon cannot reach a page's colours, so it carries its own, for a
  # light tab strip and a dark one.
  def favicon(pct = nil)
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
      <style>.o{stroke:#27231f}.w{fill:#2a5caa}@media (prefers-color-scheme:dark){.o{stroke:#efe9e1}.w{fill:#6f9be0}}</style>
      <clipPath id="c"><path d="#{OUTLINE}"/></clipPath>
      <path class="w" clip-path="url(#c)" d="#{water(pct)}"/>
      <path class="o" d="#{OUTLINE}" fill="none" stroke-width="4.5" stroke-linejoin="round"/>
      </svg>
    SVG
  end

  def favicon_href(pct) = pct ? "/favicon.svg?fill=#{pct.to_i.clamp(0, 100)}" : "/favicon.svg"

  # The mark as a 512px PNG on the app's light background, for places that
  # take no SVG -- a GitHub app's logo, for one. Rendered from the mark as
  # drawn; render it again if that changes.
  PNG = File.binread(File.expand_path("assets/logo.png", __dir__)).freeze
end
