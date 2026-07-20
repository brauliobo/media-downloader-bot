require 'spec_helper'

RSpec.describe Worker do
  it 'keeps service dependencies instance-scoped' do
    first  = double('first service')
    second = double('second service')
    msg    = SymMash.new(from: {id: 1}, chat: {id: 1})

    expect(described_class.new(msg, service: first).service).to equal(first)
    expect(described_class.new(msg, service: second).service).to equal(second)
  end

  it 'does not emit empty italic markers when caption title is blank' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    input  = SymMash.new(
      opts: SymMash.new(caption: 1),
      type: SymMash.new(name: :document),
      url:  'https://x.com/i/status/1',
      info: SymMash.new(title: '', uploader: 'Joe Tippens', description: '')
    )
    worker.instance_variable_set(:@opts, input.opts)

    expect(worker.send(:msg_caption, input, max: 1024)).to eq("Joe Tippens\n\nhttps:\\/\\/x\\.com\\/i\\/status\\/1")
  end

  it 'keeps a truncated title instead of dropping to only uploader and url' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    input  = SymMash.new(
      opts: SymMash.new(caption: 1),
      type: SymMash.new(name: :document),
      url:  'https://x.com/i/status/1',
      info: SymMash.new(title: 'A' * 2_000, uploader: 'Joe Tippens', description: '')
    )
    worker.instance_variable_set(:@opts, input.opts)

    caption = worker.send(:msg_caption, input, max: 1024)

    expect(caption.size).to be <= 1024
    expect(caption).to start_with('_AAAA')
    expect(caption).to include("_\nJoe Tippens")
  end

  it 'does not let Telegram truncate escaped Markdown inside italic markup' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    input  = SymMash.new(
      opts: SymMash.new(caption: 1),
      type: SymMash.new(name: :document),
      url:  'https://x.com/i/status/1',
      info: SymMash.new(title: '?' * 2_000, uploader: 'Slava', description: '')
    )

    caption = worker.send(:msg_caption, input, max: 1024)

    expect(caption.size).to be <= 1024
    expect(caption.scan(/(?<!\\)_/).size).to eq(2)
    expect(caption).to include("_\nSlava")
  end

  it 'closes italic markup around each paragraph in social captions' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    input  = SymMash.new(
      opts: SymMash.new(caption: 1),
      type: SymMash.new(name: :document),
      url:  nil,
      info: SymMash.new(title: "First paragraph.\n\nSecond paragraph @SpoogemanGhost", uploader: nil, description: '')
    )

    caption = worker.send(:msg_caption, input, max: 1024)

    expect(caption).to eq("_First paragraph\\._\n\n_Second paragraph @SpoogemanGhost_")
  end

  it 'uses input options when building captions' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    worker.instance_variable_set(:@opts, SymMash.new)
    input  = SymMash.new(
      opts: SymMash.new(caption: 1),
      type: SymMash.new(name: :document),
      url:  nil,
      info: SymMash.new(title: 'Input caption', uploader: nil, description: '')
    )

    expect(worker.send(:msg_caption, input, max: 1024)).to eq('_Input caption_')
  end

  it 'translates long captions paragraph by paragraph' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    body   = "First paragraph.\n\nSecond paragraph."

    allow(Translator).to receive(:translate).with('First paragraph.', from: 'en', to: 'pt').and_return('Primeiro paragrafo.')
    allow(Translator).to receive(:translate).with('Second paragraph.', from: 'en', to: 'pt').and_return('Segundo paragrafo.')

    expect(worker.send(:translate_caption_text, body, from: 'en', to: 'pt')).to eq("Primeiro paragrafo.\n\nSegundo paragrafo.")
  end

  it 'translates only caption fields with clang' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    opts   = SymMash.new(caption: 1, description: 1, clang: 'pt')
    info   = SymMash.new(title: 'English title', description: 'English description', language: 'en')

    allow(Translator).to receive(:translate).with('English title', from: 'en', to: 'pt').and_return('Titulo em portugues')
    allow(Translator).to receive(:translate).with('English description', from: 'en', to: 'pt').and_return('Descricao em portugues')

    caption_info = worker.send(:translate_caption_info, info, opts)

    expect(caption_info).to include(title: 'Titulo em portugues', description: 'Descricao em portugues')
    expect(info).to include(title: 'English title', description: 'English description')
  end

  it 'preserves slang caption translation behavior' do
    worker = described_class.new(SymMash.new(from: {id: 1}, chat: {id: 1}))
    opts   = SymMash.new(caption: 1, slang: 'pt')
    info   = SymMash.new(title: 'English title', description: '', language: 'en')

    allow(Translator).to receive(:translate).with('English title', from: 'en', to: 'pt').and_return('Titulo em portugues')

    expect(worker.send(:translate_caption_info, info, opts)).to equal(info)
    expect(info.title).to eq('Titulo em portugues')
  end
end
