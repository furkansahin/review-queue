# The mark: a drop with a little water left at the bottom. The app is named
# after Jan Adriaanszoon Leeghwater, who drained the Beemster with windmills in
# 1612, and his name means "empty water" -- which is what it does to a review
# queue.
module Logo
  OUTLINE = "M32 5C32 5 13 26 13 40C13 50.5 21.5 59 32 59C42.5 59 51 50.5 51 40C51 26 32 5 32 5Z"
  # What is left: a wave across the bottom, closed along the inside of the
  # outline -- the circle of radius 16.75 about (32, 40) that the stroke leaves.
  WATER = "M16.4 46Q20.3 42.8 24.2 46T32 46T39.8 46T47.6 46A16.75 16.75 0 0 1 16.4 46Z"

  module_function

  # For a page: the outline takes the text colour and the water the accent,
  # so it follows the page into dark mode.
  def svg(size)
    %(<svg width="#{Integer(size)}" height="#{Integer(size)}" viewBox="0 0 64 64" aria-hidden="true" ) +
      %(focusable="false" style="display: block; flex: none;">) +
      %(<path d="#{WATER}" fill="var(--accent)"/>) +
      %(<path d="#{OUTLINE}" fill="none" stroke="currentColor" stroke-width="4.5" stroke-linejoin="round"/></svg>)
  end

  # The tab icon cannot reach a page's colours, so it carries its own, for a
  # light tab strip and a dark one.
  FAVICON = <<~SVG.freeze
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    <style>.o{stroke:#27231f}.w{fill:#2a5caa}@media (prefers-color-scheme:dark){.o{stroke:#efe9e1}.w{fill:#6f9be0}}</style>
    <path class="w" d="#{WATER}"/>
    <path class="o" d="#{OUTLINE}" fill="none" stroke-width="4.5" stroke-linejoin="round"/>
    </svg>
  SVG
end
