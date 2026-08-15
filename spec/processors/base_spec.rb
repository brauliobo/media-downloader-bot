require 'spec_helper'

RSpec.describe Processors::Base do
  it 'parses options from message captions' do
    Dir.mktmpdir('base-spec-') do |dir|
      ctx = Context.new(dir: dir, msg: SymMash.new(text: '', caption: 'audio speed=1.2'))
      processor = described_class.new(ctx)

      expect(processor.opts.audio).to eq(1)
      expect(processor.opts.speed).to eq('1.2')
    end
  end

  it 'parses the hash shorthand as the canonical hashtag option' do
    Dir.mktmpdir('base-hashtags-spec-') do |dir|
      ctx = Context.new(dir: dir, line: 'https://example.com # lang=pt')
      processor = described_class.new(ctx)

      expect(processor.opts.hashtags).to eq(1)
      expect(processor.opts.slang).to eq('pt')
    end
  end

  it 'exposes the request-scoped service' do
    service   = double('service')
    processor = described_class.new(Context.new(dir: Dir.tmpdir, service: service))

    expect(processor.service).to equal(service)
  end

  describe '.add_opt' do
    it 'applies nice as a general parsed option' do
      opts = SymMash.new

      allow(Process).to receive(:setpriority)

      described_class.add_opt(opts, 'nice=19')

      expect(opts.nice).to eq('19')
      expect(Process).to have_received(:setpriority).with(Process::PRIO_PROCESS, 0, 19)
    end

    it 'normalizes all hashtag option aliases' do
      %w[hashtags hts #].each do |alias_name|
        opts = SymMash.new

        described_class.add_opt(opts, alias_name)

        expect(opts.hashtags).to eq(1)
        expect(opts.hts).to be_nil
      end
    end
  end

  describe '.normalize_options' do
    it 'normalizes merged dubbing options without losing subtitles or cuts' do
      opts = SymMash.new(dub: 'pt', lang: 'pt', to: '00:30')

      described_class.normalize_options(opts)

      expect(opts).to include(
        dub: 1, dub_lang: 'pt', sub_mode: 'language', sub_lang: 'pt',
        slang: 'pt', alang: 'pt', to: '00:30'
      )
    end

    it 'keeps generic source preferences independent from dubbing subtitles' do
      opts = SymMash.new(dub: 'pt', lang: 'es')

      described_class.normalize_options(opts)

      expect(opts).to include(
        dub: 1, dub_lang: 'pt', sub_mode: 'language', sub_lang: 'pt',
        slang: 'es', alang: 'es'
      )
    end

    it 'preserves explicit subtitle languages and modes' do
      {
        'es'     => ['language', 'es'],
        'source' => ['source', nil],
        'both'   => ['both', nil],
        'none'   => ['none', nil],
      }.each do |sub, (mode, lang)|
        opts = SymMash.new(dub: 'pt', sub: sub)

        described_class.normalize_options(opts)

        expect([opts.sub_mode, opts.sub_lang]).to eq([mode, lang])
      end
    end

    it 'uses a standalone subtitle language as the generic language fallback' do
      opts = SymMash.new(sub: 'pt')

      described_class.normalize_options(opts)

      expect(opts).to include(sub_mode: 'language', sub_lang: 'pt', slang: 'pt', alang: 'pt')
    end

    it 'keeps bare dub audio-only' do
      opts = SymMash.new(dub: 1)

      described_class.normalize_options(opts)

      expect(opts.sub_mode).to be_nil
      expect(opts.sub_lang).to be_nil
    end
  end
end
