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

    it 'uses a language-valued subtitle option as the dub language fallback' do
      opts = SymMash.new

      described_class.add_opt(opts, 'sub=pt')

      expect(opts.sub_mode).to eq('language')
      expect(opts.sub_lang).to eq('pt')
      expect(opts.slang).to eq('pt')
      expect(opts.alang).to eq('pt')
    end

    it 'keeps a language-valued dub independent while requesting matching subtitles' do
      opts = SymMash.new

      described_class.add_opt(opts, 'dub=pt')

      expect(opts.dub).to eq(1)
      expect(opts.dub_lang).to eq('pt')
      expect(opts.slang).to be_nil
      expect(opts.alang).to be_nil
      expect(opts.sub_mode).to eq('language')
      expect(opts.sub_lang).to eq('pt')
    end

    it 'keeps explicit generic language selection independent from dubbing' do
      opts = SymMash.new

      described_class.add_opt(opts, 'lang=es')
      described_class.add_opt(opts, 'dub=pt')

      expect(opts.slang).to eq('es')
      expect(opts.alang).to eq('es')
      expect(opts.dub_lang).to eq('pt')
      expect(opts.sub_lang).to be_nil
    end

    it 'does not replace an explicit subtitle mode with dub shorthand' do
      opts = SymMash.new

      described_class.add_opt(opts, 'sub=source')
      described_class.add_opt(opts, 'dub=pt')

      expect(opts.dub_lang).to eq('pt')
      expect(opts.sub_mode).to eq('source')
      expect(opts.sub_lang).to be_nil
    end

    it 'keeps bare dub audio-only' do
      opts = SymMash.new

      described_class.add_opt(opts, 'dub')

      expect(opts.dub).to eq(1)
      expect(opts.sub_mode).to be_nil
      expect(opts.sub_lang).to be_nil
    end

    it 'keeps an explicit dub language ahead of the subtitle language' do
      opts = SymMash.new

      described_class.add_opt(opts, 'lang=es')
      described_class.add_opt(opts, 'sub=pt')

      expect(opts.slang).to eq('es')
      expect(opts.alang).to eq('es')
      expect(opts.sub_lang).to eq('pt')
    end

    it 'does not use subtitle modes as dub language fallbacks' do
      opts = SymMash.new

      described_class.add_opt(opts, 'sub=source')

      expect(opts.sub_mode).to eq('source')
      expect(opts.slang).to be_nil
      expect(opts.alang).to be_nil
    end
  end
end
