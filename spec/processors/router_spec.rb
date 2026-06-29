require 'spec_helper'

RSpec.describe Processors::Router do
  it 'routes messages containing bare social urls' do
    Dir.mktmpdir('router-spec-') do |dir|
      ctx = Context.new(dir: dir, msg: SymMash.new)

      processors = described_class.for_message(ctx, ['Cloooud |🇺🇦', 'x.com/i/status/2070518837150167314'])

      expect(processors.size).to eq(1)
      expect(processors.first).to be_a(Processors::Url)
      expect(processors.first.ctx.url).to eq('https://x.com/i/status/2070518837150167314')
    end
  end

  it 'keeps options on lines after a bare url' do
    Dir.mktmpdir('router-spec-') do |dir|
      ctx = Context.new(dir: dir, msg: SymMash.new)

      processors = described_class.for_message(ctx, ['Cloooud |🇺🇦', 'x.com/i/status/2070518837150167314', 'audio'])

      expect(processors.size).to eq(1)
      expect(processors.first.ctx.url).to eq('https://x.com/i/status/2070518837150167314')
      expect(processors.first.ctx.opts.audio).to eq(1)
    end
  end
end
