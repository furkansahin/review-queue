require "openssl"

# Encryption at rest for the one secret this application holds: the SSH private
# key for a user's dev box, in dev_boxes.private_key_enc. The key stays in
# Postgres, so a database backup or a stolen dump must not reveal it.
#
# AES-256-GCM gives both secrecy and authentication: a modified ciphertext
# fails to decrypt instead of returning wrong plaintext. The key comes from
# RQ_ENCRYPTION_KEY and never goes in the database. Losing that key makes every
# stored secret unreadable, which is the correct behaviour.
module Crypto
  ALGO = "aes-256-gcm".freeze
  IV_LEN = 12
  TAG_LEN = 16
  PREFIX = "v1:".freeze

  class Error < StandardError; end

  module_function

  # 64 hex characters, that is 32 bytes: openssl rand -hex 32
  def key
    raw = ENV["RQ_ENCRYPTION_KEY"].to_s
    raise Error, "RQ_ENCRYPTION_KEY must be 64 hex characters" unless raw.match?(/\A[0-9a-fA-F]{64}\z/)
    [raw].pack("H*")
  end

  def encrypt(plaintext)
    return nil if plaintext.nil?
    return "" if plaintext.empty?

    cipher = OpenSSL::Cipher.new(ALGO).encrypt
    cipher.key = key
    iv = cipher.random_iv
    cipher.auth_data = ""
    blob = iv + cipher.update(plaintext) + cipher.final + cipher.auth_tag(TAG_LEN)
    PREFIX + [blob].pack("m0")   # strict base64; base64 is no longer a default gem
  end

  def decrypt(stored)
    return nil if stored.nil?
    return "" if stored.empty?
    raise Error, "unknown ciphertext format" unless stored.start_with?(PREFIX)

    blob = stored.delete_prefix(PREFIX).unpack1("m0").to_s
    raise Error, "ciphertext too short" if blob.bytesize <= IV_LEN + TAG_LEN

    iv = blob.byteslice(0, IV_LEN)
    tag = blob.byteslice(-TAG_LEN, TAG_LEN)
    body = blob.byteslice(IV_LEN, blob.bytesize - IV_LEN - TAG_LEN)

    cipher = OpenSSL::Cipher.new(ALGO).decrypt
    cipher.key = key
    cipher.iv = iv
    cipher.auth_tag = tag
    cipher.auth_data = ""
    # The cipher returns binary. Tag it UTF-8 or the value will not compare
    # equal to the string that was encrypted.
    (cipher.update(body) + cipher.final).force_encoding(Encoding::UTF_8)
  rescue OpenSSL::Cipher::CipherError, ArgumentError => e
    raise Error, "cannot decrypt: #{e.class}"
  end
end
