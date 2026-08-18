# A per-browser snooze list. It is kept in the encrypted session cookie, so the
# app still needs no database. A cookie holds about 4 KB, so the list is small
# and it drops the oldest entries when it is full.
#
# One rule makes this a queue and not a to-do list: new activity wakes a row.
# If a person pushes or writes a comment after you snooze a pull request, the
# row comes back immediately. You do not hide the pull request. You say
# "nothing for me until this changes".
class Snooze
  MAX_ENTRIES = 25

  # The store maps a row key to [wake_epoch, snoozed_at_epoch].
  # snoozed_at_epoch is necessary to find activity that is newer than the snooze.
  def initialize(store)
    @store = (store || {}).to_h
  end

  def add(key, seconds, now: Time.now)
    @store[key] = [(now + seconds).to_i, now.to_i]
    trim
    self
  end

  def remove(key)
    @store.delete(key)
    self
  end

  # Removes entries that are no longer necessary. Call this one time for each
  # request, before you use hidden?. An entry goes away when:
  #   - the snooze time is complete, or
  #   - the row has activity that is newer than the snooze, or
  #   - the pull request is not in the queue any more.
  def sweep(rows, now: Time.now)
    by_key = rows.each_with_object({}) { |r, h| h[r[:key]] = r }
    @store.delete_if do |key, (wake_at, snoozed_at)|
      row = by_key[key]
      next true if row.nil?
      next true if wake_at <= now.to_i
      last = row[:last_at]
      !last.nil? && last.to_i > snoozed_at
    end
    self
  end

  # Correct only after sweep. sweep removes every entry that must wake up.
  def hidden?(row) = @store.key?(row[:key])

  def wake_at(row)
    entry = @store[row[:key]]
    entry && Time.at(entry[0])
  end

  def count = @store.size

  def to_h = @store

  private

  # Keeps the entries that wake up last, because they are the newest snoozes.
  def trim
    return if @store.size <= MAX_ENTRIES
    keep = @store.sort_by { |_, (wake_at, _)| -wake_at }.first(MAX_ENTRIES)
    @store.replace(keep.to_h)
  end
end
