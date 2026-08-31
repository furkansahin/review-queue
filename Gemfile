source "https://rubygems.org"

ruby file: ".ruby-version"

gem "roda", "~> 3.86"
gem "puma", "~> 6.4"
gem "tilt", "~> 2.4"
gem "erubi", "~> 1.13"
gem "pg", "~> 1.5"
# logger stopped being a default gem in Ruby 4.0, and pg wants it.
gem "logger", "~> 1.6"
# Syntax highlighting for the code blocks in a review. Pure Ruby, no native
# extension, so it costs the deploy nothing but a gem.
gem "rouge", "~> 4.5"

group :test do
  gem "rack-test", "~> 2.2"
end
