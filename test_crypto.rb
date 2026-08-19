#!/usr/bin/env ruby
# Crypto tests:  bundle exec ruby test_crypto.rb
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64
require_relative "crypto"

$fail = 0
def check(name, got, want)
  ok = got == want
  $fail += 1 unless ok
  puts format("  %s  %-52s got=%-26s want=%s", ok ? "ok  " : "FAIL", name, got.inspect[0,26], want.inspect[0,26])
end
def raises?(klass)
  yield
  false
rescue klass
  true
end

secret = "ubi_pat_abcdef0123456789"
c = Crypto.encrypt(secret)
check("round trip", Crypto.decrypt(c), secret)
check("ciphertext is not the plaintext", c.include?(secret), false)
check("tagged with a version", c.start_with?("v1:"), true)
check("nil stays nil", Crypto.encrypt(nil), nil)
check("empty stays empty", Crypto.decrypt(Crypto.encrypt("")), "")
check("unicode survives", Crypto.decrypt(Crypto.encrypt("düğüm-🔑")), "düğüm-🔑")

# a fresh IV each time, or identical secrets would be linkable in the database
check("same input gives different ciphertext", Crypto.encrypt(secret) == Crypto.encrypt(secret), false)

# authentication: any change must fail loudly, never return wrong plaintext
blob = c.delete_prefix("v1:").unpack1("m0")
flipped = blob.dup
flipped.setbyte(20, flipped.getbyte(20) ^ 0x01)
tampered = "v1:" + [flipped].pack("m0")
check("tampered ciphertext raises", raises?(Crypto::Error) { Crypto.decrypt(tampered) }, true)
check("truncated ciphertext raises", raises?(Crypto::Error) { Crypto.decrypt("v1:" + [blob[0, 8]].pack("m0")) }, true)
check("unknown format raises", raises?(Crypto::Error) { Crypto.decrypt("plaintext") }, true)

# a different key must not decrypt
ENV["RQ_ENCRYPTION_KEY"] = "f" * 64
check("wrong key raises", raises?(Crypto::Error) { Crypto.decrypt(c) }, true)
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64

# key validation
ENV["RQ_ENCRYPTION_KEY"] = "tooshort"
check("short key rejected", raises?(Crypto::Error) { Crypto.encrypt("x") }, true)
ENV["RQ_ENCRYPTION_KEY"] = "z" * 64
check("non-hex key rejected", raises?(Crypto::Error) { Crypto.encrypt("x") }, true)
ENV["RQ_ENCRYPTION_KEY"] = "0" * 64

# tokens
t = Crypto.token
check("token is long enough", t.length >= 40, true)
check("token hash is stable", Crypto.hash_token(t), Crypto.hash_token(t))
check("different tokens hash differently", Crypto.hash_token(t) == Crypto.hash_token(Crypto.token), false)
check("hash does not contain the token", Crypto.hash_token(t).include?(t), false)
check("secure_equal? matches", Crypto.secure_equal?("abc", "abc"), true)
check("secure_equal? rejects", Crypto.secure_equal?("abc", "abd"), false)
check("secure_equal? length mismatch", Crypto.secure_equal?("abc", "abcd"), false)

check("preview masks the middle", Crypto.preview("ubi_pat_abcdef0123456789"), "ubi_********6789")
check("short secret fully masked", Crypto.preview("short"), "*****")

puts
puts($fail.zero? ? "ALL PASS" : "#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
