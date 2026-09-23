require "json"
require "time"

# A snapshot as text and back, for keeping it in the database.
#
# JSON, not Marshal. Marshal would round-trip a snapshot exactly and for free,
# and would also run whatever a crafted row told it to while loading -- so one
# write to this table would become code running on the dashboard, next to the
# key that decrypts every token. JSON only ever makes data.
#
# A snapshot is hashes with symbol keys holding strings, numbers, booleans,
# nil, Times, symbols, and one infinity (a row with no events sorts last).
# The last three have no JSON of their own, so they travel tagged.
module SnapshotCodec
  module_function

  # Spelled out: Float("Infinity") raises, it does not parse.
  SPECIAL_FLOATS = {"Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY, "NaN" => Float::NAN}.freeze

  def dump(value) = JSON.generate(encode(value))
  def load(text) = decode(JSON.parse(text))

  def encode(v)
    case v
    when Hash
      v.each_with_object({}) do |(k, x), h|
        # A string key would come back a symbol. Refuse it here, loudly, rather
        # than hand back a snapshot that is quietly not the one saved.
        raise ArgumentError, "snapshot key #{k.inspect} is not a symbol" unless k.is_a?(Symbol)
        h[k.to_s] = encode(x)
      end
    when Array then v.map { |x| encode(x) }
    when Time then {"$time" => v.iso8601(9)}
    when Symbol then {"$sym" => v.to_s}
    when Float then v.finite? ? v : {"$float" => v.to_s}
    when String, Integer, true, false, nil then v
    else raise ArgumentError, "a snapshot cannot hold a #{v.class}"
    end
  end

  def decode(v)
    case v
    when Hash
      if v.size == 1 && v.key?("$time") then Time.iso8601(v["$time"])
      elsif v.size == 1 && v.key?("$sym") then v["$sym"].to_sym
      elsif v.size == 1 && v.key?("$float") then SPECIAL_FLOATS.fetch(v["$float"])
      else v.each_with_object({}) { |(k, x), h| h[k.to_sym] = decode(x) }
      end
    when Array then v.map { |x| decode(x) }
    else v
    end
  end
end

# The last queue each person saw, kept so that a restart -- every deploy, a
# new sign-in, a day away -- shows it at once while a new one is built behind
# it, instead of making them wait out the rebuild. See QueueService#restore.
module QueueStore
  module_function

  # One person's slot. The registry hands one to each service it makes.
  def for(login) = Slot.new(login)

  Slot = Struct.new(:login) do
    # nil unless a queue was saved for exactly this question: this person,
    # asking with this key (scope, label, and the shape of a row).
    def load(key)
      row = DB.row("SELECT queue FROM saved_queues WHERE login = $1 AND key = $2", [login, key])
      return nil unless row
      snap = SnapshotCodec.load(row["queue"])
      snap.is_a?(Hash) && snap[:login] == login ? snap : nil
    rescue StandardError => e
      # An unreadable save is no save: the page builds a new one, as it would
      # have without this.
      warn "[review-queue] could not restore the queue for #{login}: #{e.class}: #{e.message}"
      nil
    end

    def save(key, snap)
      DB.exec(<<~SQL, [login, key, SnapshotCodec.dump(snap)])
        INSERT INTO saved_queues (login, key, queue, saved_at) VALUES ($1, $2, $3, now())
        ON CONFLICT (login) DO UPDATE SET key = EXCLUDED.key, queue = EXCLUDED.queue, saved_at = now()
      SQL
      true
    rescue StandardError => e
      warn "[review-queue] could not save the queue for #{login}: #{e.class}: #{e.message}"
      false
    end
  end
end
