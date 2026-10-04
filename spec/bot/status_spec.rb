require 'rails_helper'

RSpec.describe Bot::Status do
  it 'runs empty cleanup after deleting the last successful line' do
    cleaned = false
    updates = []
    status = described_class.new(on_empty: -> { cleaned = true }) { |text| updates << text }

    status.add('working') { 'ok' }

    expect(cleaned).to eq(true)
    expect(updates).to eq(['working'])
  end

  it 'keeps error lines instead of running empty cleanup' do
    cleaned = false
    status = described_class.new(on_empty: -> { cleaned = true }) { |_text| }

    status.add('working') { |line| line.error('failed') }

    expect(cleaned).to eq(false)
    expect(status.formatted).to eq('failed')
  end

  it 'posts a short sanitized exception without the backtrace' do
    updates = []
    status = described_class.new { |text| updates << text }
    error  = Nokogiri::XML::SyntaxError.new("PCDATA invalid Char value 1\n#{'x' * 5000}")
    error.set_backtrace(['lib/audiobook/parsers/pdf.rb:99'])

    status.error('Audiobook generation failed', exception: error)

    expect(updates.last).to start_with('Audiobook generation failed: Nokogiri::XML::SyntaxError:')
    expect(updates.last).not_to include('parsers/pdf.rb')
    expect(updates.last.length).to be <= 3600
  end
end
