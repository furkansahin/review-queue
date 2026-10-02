require "json"
require_relative "db"
require_relative "snooze"

# The snooze list, kept against the login rather than in the browser's
# cookie: the morning preparation runs with nobody signed in and must leave
# out what you snoozed, and a list that lives in a cookie is lost with it and
# stays behind in the browser it was made in.
module SnoozeStore
  module_function

  # The saved list, or nil when this person has never had one saved here.
  # Entries that are not [wake_at, snoozed_at] pairs are dropped rather than
  # handed to Snooze, which would raise on them.
  def load(login)
    row = DB.row("SELECT snoozed FROM user_settings WHERE login = $1", [login])
    raw = row && row["snoozed"]
    return nil if raw.nil?
    data = JSON.parse(raw)
    return {} unless data.is_a?(Hash)
    data.select { |k, v| k.is_a?(String) && v.is_a?(Array) && v.size == 2 && v.all?(Integer) }
  rescue JSON::ParserError
    {}
  end

  def save(login, store)
    DB.exec(<<~SQL, [login, JSON.generate(store.to_h)])
      INSERT INTO user_settings (login, snoozed) VALUES ($1, $2)
      ON CONFLICT (login) DO UPDATE SET snoozed = EXCLUDED.snoozed, updated_at = now()
    SQL
  end
end
