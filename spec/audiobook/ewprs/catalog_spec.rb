require 'spec_helper'
require_relative '../../../lib/audiobook/ewprs'

RSpec.describe Audiobook::Ewprs::Catalog do
  around do |example|
    original = ENV.delete('EWPRS_VOICE_REFERENCE')
    example.run
  ensure
    original ? ENV['EWPRS_VOICE_REFERENCE'] = original : ENV.delete('EWPRS_VOICE_REFERENCE')
  end

  it 'uses the recorded reference and neutral English instruction when configured' do
    Dir.mktmpdir('ewprs-') do |root|
      reference = File.join(root, 'speaker.wav')
      File.write(reference, 'wav')
      File.write(File.join(root, 'speaker.txt'), "An exact recorded reference sentence.\n")
      ENV['EWPRS_VOICE_REFERENCE'] = reference
      entry = described_class::Entry.new(kind: :discourse, title: 'English title', path: '/tmp/discourse.html')

      options = described_class.new(root).parse_options(entry)

      expect(options.instruct).to eq('male, middle-aged, moderate pitch, neutral English accent')
      expect(options.speaker_wav).to eq(reference)
      expect(options.ref_text).to eq('An exact recorded reference sentence.')
    end
  end

  it 'configures Portuguese parsing and narration' do
    Dir.mktmpdir('ewprs-') do |root|
      entry = described_class::Entry.new(kind: :discourse, title: 'Título traduzido', path: '/tmp/discourse.html')
      catalog = described_class.new(root, language: 'pt')

      options = catalog.parse_options(entry)

      expect(catalog.language_name).to eq('Portuguese')
      expect(options.html_title).to eq('Título traduzido')
      expect(options.html_language).to eq('pt')
      expect(options.instruct).to eq('male, middle-aged, moderate pitch, portuguese accent')
    end
  end

  it 'uses translated titles from discourse and book files' do
    Dir.mktmpdir('ewprs-') do |root|
      FileUtils.mkdir_p(File.join(root, 'HTML/Navigation'))
      FileUtils.mkdir_p(File.join(root, 'HTML/Discourses'))
      FileUtils.mkdir_p(File.join(root, 'HTML/Books'))
      File.write(
        File.join(root, 'HTML/Navigation/alphabetical.html'),
        '<div class=list_discourse_title><a href="../Discourses/Work.html">English discourse</a></div>' \
        '<div>info</div><div>references</div>'
      )
      File.write(
        File.join(root, 'HTML/Navigation/books_tocs.html'),
        '<div class=books_book_title_tocs><a href="../Books/Book.html">English book</a></div><div></div>'
      )
      File.write(
        File.join(root, 'HTML/Discourses/Work.html'),
        '<div class=discourse_box_references><a href="../Books/Book.html">Livro traduzido</a></div>' \
        '<div class=discourse_title>Discurso traduzido</div>' \
        '<div class=discourse_info>22 de setembro de 1985, Calcutá</div>'
      )
      File.write(File.join(root, 'HTML/Books/Book.html'), '<div class=book_title>Livro traduzido</div>')
      catalog = described_class.new(root, language: 'pt')

      expect(catalog.discourses.first.title).to eq('Discurso traduzido')
      expect(catalog.discourses.first.info).to eq('22 de setembro de 1985, Calcutá')
      expect(catalog.discourses.first.sources).to eq(['Livro traduzido'])
      expect(catalog.books.first.title).to eq('Livro traduzido')
    end
  end
end
