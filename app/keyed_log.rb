# An append-only JSONL log of records unique by `fields`: what was already done, so a repeated or resumed run skips it.
class KeyedLog
  class_attribute :fields

  def initialize(path)
    @store = JsonlStore.new(path)
    @mutex = Mutex.new
  end

  def include?(record) = @mutex.synchronize { keys.include?(record.values_at(*fields)) }

  def add(record)
    @mutex.synchronize do
      @store.append(record)
      keys << record.values_at(*fields)
    end
  end

  def remove(record)
    @mutex.synchronize do
      keys.delete(record.values_at(*fields))
      @store.rewrite(@store.reject { |stored| stored.values_at(*fields) == record.values_at(*fields) })
    end
  end

  def records = @store.to_a

  private

  def keys = @keys ||= Set.new(@store.map { |record| record.values_at(*fields) })
end
