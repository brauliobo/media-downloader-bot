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

  it 'applies base options and per-url overrides to multiple inputs' do
    Dir.mktmpdir('router-spec-') do |dir|
      ctx = Context.new(dir: dir, msg: SymMash.new)

      processors = described_class.for_message(ctx, ['audio speed=1.0', 'x.com/a', 'speed=1.2', 'x.com/b', 'speed=1.5'])

      expect(processors.size).to eq(2)
      expect(processors.map { |processor| processor.ctx.opts.audio }).to eq([1, 1])
      expect(processors.map { |processor| processor.ctx.opts.speed }).to eq(['1.2', '1.5'])
    end
  end

  it 'routes an attached pdf whose caption looks like a filename as a document' do
    Dir.mktmpdir('router-spec-') do |dir|
      filename = 'Como se tornar sobrenatural Joe Dispenza 1.pdf'
      msg = SymMash.new(
        text: filename,
        document: SymMash.new(file_name: filename, mime_type: 'application/pdf'),
      )
      ctx = Context.new(dir: dir, msg: msg)
      lines = Utils::InputParser.message_lines(msg)

      processors = described_class.for_message(ctx, lines)

      expect(processors.size).to eq(1)
      expect(processors.first).to be_a(Processors::Document)
    end
  end

  it 'does not treat urls in an attached file caption as download inputs' do
    Dir.mktmpdir('router-spec-') do |dir|
      filename = 'book.pdf'
      msg = SymMash.new(
        text: "#{filename} https://example.com/v audio",
        document: SymMash.new(file_name: filename, mime_type: 'application/pdf'),
      )
      ctx = Context.new(dir: dir, msg: msg)
      lines = Utils::InputParser.message_lines(msg)

      processors = described_class.for_message(ctx, lines)

      expect(processors.size).to eq(1)
      expect(processors.first).to be_a(Processors::Document)
      expect(processors.first.ctx.url).to be_nil
      expect(processors.first.ctx.opts.audio).to eq(1)
    end
  end

  it 'keeps attached videos even when the caption contains a url' do
    Dir.mktmpdir('router-spec-') do |dir|
      msg = SymMash.new(
        text: 'https://example.com/v audio',
        video: SymMash.new(file_name: 'clip.mp4'),
      )
      ctx = Context.new(dir: dir, msg: msg)
      lines = Utils::InputParser.message_lines(msg)

      processors = described_class.for_message(ctx, lines)

      expect(processors.size).to eq(1)
      expect(processors.first).to be_a(Processors::Video)
      expect(processors.first.ctx.url).to be_nil
      expect(processors.first.ctx.opts.audio).to eq(1)
    end
  end
end
