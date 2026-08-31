require "openssl"
require_relative "crypto"

# One remote box per user: what it is, and what a person is allowed to say
# about it. Reaching it is Runner's job.
#
# The keypair is generated HERE and the user installs only the public half, so
# no personal SSH key ever enters the system and deleting the row is a real
# revocation. The private half is encrypted at rest.
#
# The rest of this file is validation, and it is written to be strict rather
# than forgiving: a host, a user, a repository path and a skills URL all end up
# in a config file or a command on somebody's machine, so each one is checked
# against what it is allowed to be and refused otherwise, never cleaned up.
module BayBox
  class Error < StandardError; end

  BOX_PREFIX = "rq".freeze

  # ed25519, not RSA.
  #
  # The line a person pastes into authorized_keys was 758 characters of base64
  # that wrapped over half a dozen lines and looked like damage. The same key
  # as ed25519 is 105 characters and fits on one. It is also the modern default
  # and generates in a fraction of a millisecond rather than a tenth of a
  # second, which is the pause between pressing Register and seeing the page.
  #
  # This was not possible while net-ssh was the transport: it needs two more
  # gems to touch an ed25519 key at all. bay drives a real ssh binary now, and
  # OpenSSH has read this key format for years -- checked with ssh-keygen -y
  # against a key generated exactly this way.
  KEY_TYPE = "ED25519".freeze
  KEY_NAME = "ssh-ed25519".freeze

  module_function

  # Returns [private_key_pem, openssh_public_key]. Keys made before this was
  # ed25519 are RSA and keep working: they are stored, not regenerated, and
  # nothing here re-derives a public key from a private one.
  def generate_keypair(comment: "review-queue")
    key = OpenSSL::PKey.generate_key(KEY_TYPE)
    [key.private_to_pem, openssh_public(key, comment)]
  end

  # The ssh wire format for an ed25519 public key: the string "ssh-ed25519",
  # then the 32 raw bytes, each length-prefixed with a 32-bit big-endian count.
  # Short enough to write out rather than take a dependency for.
  def openssh_public(key, comment)
    blob = ssh_string(KEY_NAME) + ssh_string(key.raw_public_key)
    "#{KEY_NAME} #{[blob].pack("m0")} #{comment}"
  end

  def ssh_string(value) = [value.bytesize].pack("N") + value

  # The line a user pastes into ~/.ssh/authorized_keys on their machine.
  #
  # bay needs git and docker over this connection, so the key logs in rather
  # than running one program. `restrict` is what survives that: no port
  # forwarding, no agent forwarding, no X11, no pty -- bay uses none of them.
  def authorized_keys_line(public_key)
    %(restrict #{public_key})
  end

  # A box name derived from the pull request, so a repeat review reuses it.
  #
  # The whole repository, not just its last segment: ubicloud/ubicloud and
  # furkansahin/ubicloud used to collide on rq-ubicloud-5, sharing one state
  # directory and one log, so each published the other's review and tearing one
  # down removed the other's box.
  #
  # Lowercased and non-alphanumerics folded to dashes, because BOX_RE accepts
  # neither uppercase nor dots -- ubicloud/Bay was otherwise unreviewable, with
  # an error naming a box name the user never typed.
  MAX_BOX = 49

  def box_name(repo, pr_number)
    slug = repo.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    suffix = "-#{pr_number}"
    room = MAX_BOX - BOX_PREFIX.length - 1 - suffix.length
    "#{BOX_PREFIX}-#{slug[0, [room, 1].max]}#{suffix}"
  end

  # Single quotes, for a path that is built here and read by a remote shell.
  # Everything inside single quotes is literal to a shell except a single quote
  # itself, which is closed, escaped and reopened.
  def sh_quote(value) = "'" + value.to_s.gsub("'", %q('"'"')) + "'"

  # A host is a name or an address; no spaces, no shell characters, no scheme.
  HOST_RE = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,252}\z/
  USER_RE = /\A[a-z_][a-z0-9_-]{0,31}\z/

  def check_target!(host:, ssh_user:, port:)
    raise Error, "enter a host name or IP address" unless host.to_s.strip.match?(HOST_RE)
    raise Error, "invalid ssh user" unless ssh_user.to_s.strip.match?(USER_RE)
    p = port.to_s.strip
    raise Error, "port must be between 1 and 65535" unless p.match?(/\A[0-9]{1,5}\z/) && (1..65_535).cover?(p.to_i)
    {host: host.to_s.strip, ssh_user: ssh_user.to_s.strip, port: p.to_i}
  end

  # A skills repository is typed by a person and ends up in a TOML file that
  # bay hands to `git clone` inside a container, so only one shape passes.
  # GitHub over
  # https is the only shape that works anyway: that is what bay's credential
  # helper authenticates with GITHUB_TOKEN. Anything carrying its own
  # credentials, another host, or a character that is not in a repository name
  # is refused rather than cleaned up.
  SKILLS_RE = %r{\Ahttps://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(?:\.git)?\z}

  # Returns the URL to store, or nil for "no skills repository". Accepts the
  # owner/name shorthand and writes it out in full, because that is what people
  # type and the long form is what bay needs.
  def check_skills_repo!(value)
    v = value.to_s.strip
    return nil if v.empty?
    v = "https://github.com/#{v}" if v.match?(REPO_RE)
    v = v.chomp("/")
    unless v.match?(SKILLS_RE)
      raise Error, "skills repository must be a GitHub https URL, " \
                   "like https://github.com/you/skills (got #{shown(value)})"
    end
    v
  end

  # Where the repo sits on the user's own machine. It is written into a TOML
  # file and handed to bay, which passes it to ssh, so it stays a plain
  # home-relative path: no traversal, no absolute path, no shell characters.
  def check_repo_path!(value)
    v = value.to_s.strip.sub(%r{\A~/}, "").chomp("/")
    return nil if v.empty?
    unless v.match?(%r{\A[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*\z}) && !v.split("/").include?("..")
      raise Error, "repo path must be a plain path under the home directory, like ubicloud (got #{shown(value)})"
    end
    v
  end

  REPO_RE = %r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}
  BOX_RE = /\A[a-z0-9][a-z0-9-]{0,48}\z/

  # The message names the value it rejected. Without that, "bad repo" sends you
  # hunting through the code instead of telling you the form sent the bare
  # repository name, or nothing at all.
  def validate!(repo:, pr_number:, box:)
    raise Error, "bad repo #{shown(repo)} (expected owner/name)" unless repo.to_s.match?(REPO_RE)
    raise Error, "bad pull request number #{shown(pr_number)}" unless pr_number.to_s.match?(/\A[0-9]{1,7}\z/)
    raise Error, "bad box name #{shown(box)}" unless box.to_s.match?(BOX_RE)
    true
  end

  def shown(value)
    v = value.to_s
    return "(empty)" if v.empty?
    v.length > 40 ? "#{v[0, 40].inspect}…" : v.inspect
  end
end
