require "net/http"
require "uri"
require "fileutils"

# Skills every run applies, whoever it runs for and whatever their own skills
# repository holds -- jeremy-lens, to start with.
#
# A person's skills repository is installed in their box by bay, but whether a
# skill there is used was left to the model: it loads one when it judges the
# description fits, and on most reviews it judged jeremy-lens did not. So these
# are not left to that. Each run gets its own copy under .rq/skills/<name>/,
# fetched fresh from the repository that holds them, and its prompt says to
# read and apply them before anything else. A person without the repository
# gets them all the same.
module AlwaysSkills
  NAMES = ENV.fetch("RQ_ALWAYS_SKILLS", "jeremy-lens").split(",").map(&:strip)
                 .select { |n| n.match?(/\A[a-z0-9][a-z0-9._-]{0,63}\z/) }.freeze
  REPO = ENV.fetch("RQ_ALWAYS_SKILLS_REPO", "https://github.com/furkansahin/skills")
  MAX_BYTES = 200_000
  # A fetch this recent is used as it is.
  FRESH = 15 * 60

  module_function

  def repo_path = REPO[%r{github\.com/([\w.-]+/[\w.-]+?)(?:\.git)?/?\z}, 1]

  def dir(root) = File.join(root, "always-skills")

  # [[name, local path of its SKILL.md]] for each skill there is a copy of:
  # fetched now when the copy is older than FRESH, the last good copy when
  # GitHub cannot be reached, left out when there has never been one.
  def files(root, log: ->(_) {})
    NAMES.filter_map do |name|
      path = File.join(dir(root), name, "SKILL.md")
      stale = !File.exist?(path) || Time.now - File.mtime(path) > FRESH
      if stale
        begin
          body = fetch(name)
          FileUtils.mkdir_p(File.dirname(path))
          File.write("#{path}.tmp", body)
          File.rename("#{path}.tmp", path)
        rescue StandardError => e
          log.call("could not fetch the #{name} skill: #{e.class}: #{e.message[0, 200]}" \
                   "#{File.exist?(path) ? "; using the copy from #{File.mtime(path).utc}" : ""}")
        end
      end
      [name, path] if File.size?(path)
    end
  end

  def fetch(name)
    repo = repo_path or raise "RQ_ALWAYS_SKILLS_REPO is not a GitHub repository: #{REPO}"
    uri = URI("https://raw.githubusercontent.com/#{repo}/HEAD/#{name}/SKILL.md")
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
      http.request(Net::HTTP::Get.new(uri, "User-Agent" => "leeghwater"))
    end
    raise "GitHub answered #{res.code} for #{name}/SKILL.md" unless res.is_a?(Net::HTTPSuccess)
    body = res.body.to_s
    raise "#{name}/SKILL.md is empty" if body.strip.empty?
    raise "#{name}/SKILL.md is over #{MAX_BYTES} bytes" if body.bytesize > MAX_BYTES
    body
  end
end
