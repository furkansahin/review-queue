require "openssl"
require "net/ssh"
require "timeout"
require_relative "crypto"

# One remote dev box per user. The dashboard connects to it and asks bay to
# start a review session there.
#
# The keypair is generated HERE and the user installs only the public half, so
# no personal SSH key ever enters the system and deleting the row is a real
# revocation. The private half is encrypted at rest.
#
# The user installs it with a forced command, so the key cannot become a shell:
#
#   command="/usr/local/bin/rq-review",restrict ssh-rsa AAAA... review-queue
#
# Everything the dashboard sends arrives as $SSH_ORIGINAL_COMMAND, and the
# wrapper on the box decides whether to honour it. The dashboard therefore
# never builds a shell string, and a stolen key can start reviews and nothing
# else.
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

  # ssh-rsa wire format: string "ssh-rsa", then mpint e, then mpint n.
  def openssh_public(key, comment)
    blob = ssh_string("ssh-rsa") + ssh_mpint(key.e) + ssh_mpint(key.n)
    "ssh-rsa #{[blob].pack("m0")} #{comment}"
  end

  def ssh_string(value) = [value.bytesize].pack("N") + value

  def ssh_mpint(bn)
    bytes = bn.to_s(2)
    bytes = "\x00".b + bytes if bytes.bytes.first.to_i >= 0x80   # keep it positive
    [bytes.bytesize].pack("N") + bytes
  end

  # The exact line the user pastes into ~/.ssh/authorized_keys on their box.
  def authorized_keys_line(public_key, wrapper: "/usr/local/bin/rq-review")
    %(command="#{wrapper}",restrict #{public_key})
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

  # The command sent to the box. With a forced command it is not interpreted by
  # a shell there: it arrives whole in $SSH_ORIGINAL_COMMAND and the wrapper
  # validates every field before it runs bay.
  def review_command(repo:, pr_number:, box:)
    validate!(repo: repo, pr_number: pr_number, box: box)
    ["review", repo, pr_number.to_s, box].join(" ")
  end

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

  # Runs one command and returns {ok:, output:, exit_code:}. Never raises for a
  # non-zero exit: a failing review is data, not an exception.
  # stdin carries free text (a follow-up question) so it never reaches a command
  # line, where it would have to be quoted and could affect parsing.
  def run(box_row, command, timeout: 30, stdin: nil)
    key = Crypto.decrypt(box_row["private_key_enc"])
    output = +""
    code = nil

    Net::SSH.start(
      box_row["host"], box_row["ssh_user"],
      port: Integer(box_row["port"]),
      key_data: [key], keys: [], keys_only: true, use_agent: false,
      non_interactive: true, timeout: timeout,
      verify_host_key: :never   # the forced command is the control, not the host key
    ) do |ssh|
      ssh.open_channel do |ch|
        ch.exec(command) do |_, success|
          raise Error, "could not start the command on the dev box" unless success
          if stdin
            ch.send_data(stdin)
            ch.eof!
          end
          ch.on_data { |_, d| output << d }
          ch.on_extended_data { |_, _, d| output << d }
          ch.on_request("exit-status") { |_, data| code = data.read_long }
        end
      end
      # Net::SSH's :timeout bounds connect/version/KEX only, and loop with no
      # wait blocks in IO.select indefinitely. A box that accepts TCP but never
      # finishes the command would otherwise hold a Puma thread, or the single
      # worker loop, for good.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      ssh.loop(0.1) do
        raise Timeout::Error, "no reply from the dev box after #{timeout}s" \
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        true
      end
    end

    # code stays nil when the channel closed without an exit-status request --
    # a dropped connection, a killed box. nil.to_i is 0, so `code.to_i.zero?`
    # called that success, and teardown then reported "tore down" for a box that
    # is still there. Only a real zero counts.
    {ok: code == 0, output: output, exit_code: code}
  rescue Crypto::Error => e
    {ok: false, output: "", exit_code: nil,
     error: "cannot read the stored key: #{e.message}. Is RQ_ENCRYPTION_KEY set correctly?"}
  rescue Net::SSH::Exception, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
         SocketError, IOError, Timeout::Error => e
    {ok: false, output: "", exit_code: nil, error: "#{e.class}: #{e.message}"}
  end

  # Cheapest call that proves the key is installed and the wrapper is present.
  def check(box_row) = run(box_row, "ping")
end
