require "openssl"
# Only for OpenSSL key #to_blob, which writes the ssh wire format. This module
# used to be the transport as well; bay is, now. One dependency for one method
# is still better than encoding "string, mpint e, mpint n" by hand.
require "net/ssh"
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
module DevBox
  class Error < StandardError; end

  BOX_PREFIX = "rq".freeze
  KEY_BITS = 4096

  module_function

  # Returns [private_key_pem, openssh_public_key].
  def generate_keypair(comment: "review-queue")
    key = OpenSSL::PKey::RSA.generate(KEY_BITS)
    [key.to_pem, openssh_public(key, comment)]
  end

  def openssh_public(key, comment) = "ssh-rsa #{[key.to_blob].pack("m0")} #{comment}"

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
