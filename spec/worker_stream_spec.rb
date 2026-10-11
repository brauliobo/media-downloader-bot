require 'rails_helper'

RSpec.describe WorkerStream do
  it 'keeps `size` items in flight while a lazy producer feeds it, and waits for all of them on close' do
    mutex, running, peak, done = Mutex.new, 0, 0, []
    stream = described_class.new(3) do |item|
      mutex.synchronize { peak = [peak, running += 1].max }
      sleep 0.02
      mutex.synchronize { running -= 1; done << item }
    end

    (1..12).each { |item| stream << item }
    stream.close

    expect(done.sort).to eq((1..12).to_a)
    expect(peak).to eq(3)
  end
end
