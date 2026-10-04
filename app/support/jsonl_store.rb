require 'json'

class JsonlStore
  include Enumerable

  attr_reader :path

  def initialize(path)
    @path = File.expand_path(path)
  end

  def each
    return enum_for(:each) unless block_given?
    return unless File.exist?(path)

    File.foreach(path) do |line|
      next if line.strip.empty?

      yield JSON.parse(line, symbolize_names: true)
    end
  end

  def append(record)
    File.open(path, 'a') do |file|
      file.puts JSON.generate(record)
      file.flush
      file.fsync
    end
    record
  end
end
