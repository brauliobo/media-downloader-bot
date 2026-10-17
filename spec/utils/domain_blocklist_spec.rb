require 'rails_helper'

RSpec.describe Utils::DomainBlocklist do
  before { allow(described_class).to receive(:domains).and_return(Set['blocked.example']) }

  it 'blocks a listed domain and its subdomains only' do
    expect(described_class.blocked?('blocked.example')).to be(true)
    expect(described_class.blocked?('www.blocked.example')).to be(true)
    expect(described_class.blocked?('notblocked.example')).to be(false)
    expect(described_class.blocked?('example')).to be(false)
  end

  it 'blocks a redirect link to a listed domain' do
    Dir.mktmpdir('blocklist-spec-') do |dir|
      ctx = Context.new(dir: dir, line: 'https://google.com/url?q=1&url=https://www.blocked.example/v/1')

      expect { Processors::Base.new(ctx) }.to raise_error('Blocked domain')
    end
  end
end
