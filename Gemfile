source "https://rubygems.org"

ruby file: ".ruby-version"

gem "roda", "~> 3.86"
gem "puma", "~> 6.4"
gem "tilt", "~> 2.4"
gem "erubi", "~> 1.13"
gem "pg", "~> 1.5"
# net-ssh requires logger, which stopped being a default gem in Ruby 4.0
gem "net-ssh", "~> 7.2"
gem "logger", "~> 1.6"

group :test do
  gem "rack-test", "~> 2.2"
end
