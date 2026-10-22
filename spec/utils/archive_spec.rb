require 'rails_helper'
require 'tmpdir'

RSpec.describe Utils::Archive do
  let(:limits) { { max_entries: 10, max_entry_bytes: 1 << 20, max_total_bytes: 1 << 20, max_ratio: 100 } }

  # A zip with one stored entry whose timestamp has day 0 and month 0, as some epubs do.
  def zip_with_zero_date(path)
    data, name = 'hello', 'a.txt'
    local   = [0x04034b50, 20, 0, 0, 0, 0, 0, data.size, data.size, name.size, 0].pack('VvvvvvVVVvv') + name + data
    central = [0x02014b50, 20, 20, 0, 0, 0, 0, 0, data.size, data.size, name.size, 0, 0, 0, 0, 0, 0].pack('VvvvvvvVVVvvvvvVV') + name
    ending  = [0x06054b50, 0, 0, 1, 1, central.size, local.size, 0].pack('VvvvvVVv')
    File.binwrite(path, local + central + ending)
  end

  it 'validates an archive whose entries have an impossible timestamp' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.epub').tap { |file| zip_with_zero_date(file) }

      expect { described_class.validate_zip!(path, **limits) }.not_to raise_error
    end
  end

  it 'reads an impossible timestamp as the DOS epoch' do
    expect(Archive::Zip::DOSTime.new(0).to_time).to eq(Time.local(1980, 1, 1))
  end
end
