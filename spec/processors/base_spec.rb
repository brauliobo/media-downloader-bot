require 'rails_helper'

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

  describe 'chat default options' do
    let(:chat_id) { -9_000_000_001 }
    let(:other)   { -9_000_000_002 }

    around do |example|
      ChatSetting.db.transaction(rollback: :always, auto_savepoint: true) do
        ChatSetting.update_settings(chat_id, options: 'lang=pt # dub=en')
        example.run
      end
    end

    def opts_for(chat, caption, **msg)
      Dir.mktmpdir { |dir| described_class.new(Context.new(dir: dir, msg: SymMash.new(chat: {id: chat}, caption: caption, **msg))).opts }
    end

    it 'applies them through the usual normalization when the message has none' do
      expect(opts_for(chat_id, 'audio')).to include(audio: 1, hashtags: 1, lang: 'pt', slang: 'pt', alang: 'pt', dub: 1, dub_lang: 'en')
    end

    it 'applies them to a document sent without a caption' do
      opts = opts_for(chat_id, nil, document: {file_name: 'book.pdf', mime_type: 'application/pdf'})

      expect(opts).to include(hashtags: 1, lang: 'pt')
    end

    it 'lets the options typed on the message win' do
      expect(opts_for(chat_id, 'lang=en hts=0')).to include(lang: 'en', alang: 'en', slang: 'en', hashtags: '0')
      expect(opts_for(chat_id, 'slang=es')).to include(lang: 'pt', alang: 'pt', slang: 'es', hashtags: 1)
    end

    it 'leaves other chats and messages without chat info alone' do
      expect(opts_for(other, 'audio').keys).to contain_exactly(:audio, :session)
      expect(described_class.new(Context.new(dir: Dir.tmpdir, msg: SymMash.new(caption: 'audio'))).opts.keys).to contain_exactly(:audio, :session)
    end
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
    it 'keeps dubbing, subtitle, and legacy language responsibilities distinct' do
      [
        [{dub: 'pt'}, {dub: 1, dub_lang: 'pt', sub_mode: 'language', sub_lang: 'pt'}],
        [{sub: 'pt'}, {sub: 'pt', sub_mode: 'language', sub_lang: 'pt'}],
        [{lang: 'pt'}, {lang: 'pt', slang: 'pt', alang: 'pt'}],
        [{dub: 'pt', lang: 'es'}, {
          dub: 1, dub_lang: 'pt', sub_mode: 'language', sub_lang: 'pt', lang: 'es', slang: 'es', alang: 'es'
        }],
      ].each do |input, expected|
        opts = SymMash.new(input)

        described_class.normalize_options(opts)

        expect(opts).to include(expected)
        expect(opts[:lang]).to eq(input[:lang])
        expect(opts.slang).to be_nil unless input.key?(:lang)
        expect(opts.alang).to be_nil unless input.key?(:lang)
      end
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

    it 'keeps bare dub audio-only' do
      opts = SymMash.new(dub: 1)

      described_class.normalize_options(opts)

      expect(opts.sub_mode).to be_nil
      expect(opts.sub_lang).to be_nil
    end

    it 'lets lang= replace an existing subtitle language' do
      opts = SymMash.new(slang: 'en', alang: 'en', lang: 'pt')

      described_class.normalize_options(opts)

      expect(opts).to include(lang: 'pt', slang: 'pt', alang: 'pt')
    end

    it 'canonicalizes gensub as gensubs' do
      opts = SymMash.new(gensub: 1)

      described_class.normalize_options(opts)

      expect(opts.gensubs).to eq(1)
      expect(opts.gensub).to be_nil
    end
  end
end
