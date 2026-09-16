require 'spec_helper'

# Each fixture is a page range lifted from a book a user sent to the bot, kept for the specific
# assembly defect it exposes: font metrics, page furniture, references, or heading classification.
RSpec.describe 'Audiobook assembly regressions' do
  def fixture(name) = File.expand_path("../fixtures/audiobook/#{name}", __dir__)

  def book_for(name, lang)
    Audiobook::Book.from_input(fixture(name), opts: SymMash.new(alang: lang), translate: false)
  end

  def items(book)     = book.pages.flat_map(&:items)
  def paragraphs(book) = items(book).grep(Audiobook::Paragraph)
  def paragraph_texts(book) = paragraphs(book).map { |para| para.sentences.map(&:text).join(' ') }
  def sentences(book) = paragraphs(book).flat_map(&:sentences)
  def headings(book)  = items(book).grep(Audiobook::Heading).map(&:text)
  def references(book) = sentences(book).flat_map(&:references)
  def spoken(book)    = (paragraph_texts(book) + headings(book)).join("\n")

  describe 'kybalion-dropcap-roman-pages.pdf' do
    let(:book) { book_for('kybalion-dropcap-roman-pages.pdf', 'en') }

    it 'folds the drop cap into the word it opens' do
      expect(paragraph_texts(book).first).to start_with('We take great pleasure in presenting')
      expect(headings(book)).not_to include('W')
    end

    it 'drops roman folios instead of reading them mid-sentence' do
      expect(spoken(book)).to include('elapsed since the lifetime of its great founder')
      expect(headings(book)).not_to include('ix', 'x')
    end

    it 'drops running heads but keeps the chapter title' do
      expect(headings(book)).not_to include('The Kybalion', 'Introduction')
      expect(paragraph_texts(book)).not_to include('The Kybalion', 'Introduction')
      expect(headings(book)).to include('Introduction.')
    end

    it 'joins a paragraph that continues on the next page' do
      expect(spoken(book)).to include('by a few men in each age, who, refusing great numbers')
    end
  end

  describe 'kybalion-toc-leaders.pdf' do
    let(:book) { book_for('kybalion-toc-leaders.pdf', 'en') }

    it 'reads table-of-contents entries without their leader dots' do
      expect(paragraph_texts(book)).to include(
        'Chapter I. The Hermetic Philosophy.', 'Chapter II. The Seven Hermetic Principles.'
      )
      expect(spoken(book)).not_to match(/\.{4}|…{2}/)
    end
  end

  describe 'salud-softhyphen-font-metrics.pdf' do
    let(:book) { book_for('salud-softhyphen-font-metrics.pdf', 'es') }

    it 'rejoins words broken by a soft hyphen' do
      expect(spoken(book)).to include('Su respuesta fue simple, me dijo:')
      expect(spoken(book)).to include('siga únicamente sus propias conclusiones')
      expect(spoken(book)).not_to match(/\bsim\s+ple\b/)
    end

    it 'keeps one run together when tall glyphs stretch the line box' do
      expect(paragraph_texts(book)).to include(a_string_including('Le hice caso y me puse a trabajar.'))
    end
  end

  describe 'sim-senhor-dialogue-font.pdf' do
    let(:book) { book_for('sim-senhor-dialogue-font.pdf', 'pt') }

    it 'keeps dialogue as prose instead of promoting every line to a section' do
      expect(items(book).grep(Audiobook::Section)).to be_empty
      expect(paragraph_texts(book)).to include(a_string_including('― A nós dois ― ele concordou e brindamos.'))
    end

    it 'drops the author running head and joins the line it interrupted' do
      expect(spoken(book)).not_to include('Danúbia Ferreira')
      expect(spoken(book)).to include('Antes do sexo, pre-cisávamos conversar.')
    end
  end

  describe 'mms-smallcaps-toc.pdf' do
    let(:book) { book_for('mms-smallcaps-toc.pdf', 'pt') }

    it 'joins small-capital runs back into their word' do
      expect(spoken(book)).to include('DESENVOLVIMENTO DE NOVOS PROTOCOLOS')
      expect(spoken(book)).not_to include('D ESENVOLVIMENTO')
    end

    it 'strips contents leaders and the page number they point at' do
      expect(spoken(book)).not_to match(/\.{4}/)
    end
  end

  describe 'mms-running-heads.pdf' do
    let(:book) { book_for('mms-running-heads.pdf', 'pt') }

    it 'reads the chapter title once instead of on every page' do
      expect(headings(book).count { |text| text.include?('PREFÁCIO') }).to eq(1)
    end

    it 'keeps thousands separators out of the reference machinery' do
      expect(spoken(book)).to include('mais de 10.000 e-mails')
      expect(spoken(book)).to include('outros 50.000 e-mails')
      expect(references(book)).to be_empty
    end

    it 'finds the bold section headings inside the body' do
      expect(headings(book)).to include('Desenvolvimento De Novos Protocolos')
    end
  end

  describe 'guia-size-jitter-running-heads.pdf' do
    let(:book) { book_for('guia-size-jitter-running-heads.pdf', 'pt') }

    it 'drops roman folios and the running head' do
      expect(spoken(book)).not_to include('MMS Health Recovery Guldebook')
      expect(headings(book)).not_to include('XV', 'XVI')
      expect(headings(book)).to include('Prefácio')
    end

    it 'keeps a machine-translated page in a few paragraphs despite per-line size jitter' do
      expect(book.pages.first.items.grep(Audiobook::Paragraph).size).to be <= 4
    end
  end

  describe 'nao-comecou-line-font-jitter.pdf' do
    let(:book) { book_for('nao-comecou-line-font-jitter.pdf', 'pt') }

    it 'drops the translation watermark' do
      expect(spoken(book)).not_to include('Machine Translated by Google')
    end

    it 'resumes a sentence across a line whose font size jumps' do
      expect(spoken(book)).to include('Sempre que eu ouvi dizer que poderia haver alguém')
      expect(items(book).grep(Audiobook::Section)).to be_empty
    end
  end

  describe 'nao-comecou-curly-quote-marker.pdf' do
    let(:book) { book_for('nao-comecou-curly-quote-marker.pdf', 'pt') }

    it 'takes a marker off a closing curly quote' do
      expect(spoken(book)).not_to include('acontecendo.”1')
      expect(spoken(book)).to include('o que está acontecendo.”')
      expect(references(book).map(&:id)).to include('1')
    end
  end

  describe 'fixing-gaze-year-as-reference.pdf' do
    let(:book) { book_for('fixing-gaze-year-as-reference.pdf', 'en') }

    it 'separates an endnote call glued onto a year' do
      expect(spoken(book)).to include('her experiences in 2006.')
      expect(spoken(book)).not_to include('2006.1')
    end

    it 'leaves the following sentence in the body instead of moving it into a note' do
      expect(paragraph_texts(book)).to include(a_string_including('But that was not the end of the matter.'))
      expect(references(book).map(&:sentences)).to all(be_empty)
    end
  end

  describe 'savin-thousands-split-reference.pdf' do
    let(:book) { book_for('savin-thousands-split-reference.pdf', 'en') }

    it 'keeps a thousands separator intact and raises no reference' do
      expect(spoken(book)).to include('over 195,000 federal sealed indictments')
      expect(references(book)).to be_empty
    end

    it 'keeps initials attached to the name they abbreviate' do
      expect(paragraph_texts(book)).not_to include(a_string_ending_with(' U.'))
    end
  end

  describe 'matriz-decimal-marker.pdf' do
    let(:book) { book_for('matriz-decimal-marker.pdf', 'pt') }

    it 'leaves a catalogue decimal alone' do
      expect(spoken(book)).to include('CDD-299.93')
      expect(references(book)).to be_empty
    end
  end

  describe 'janval-glued-superscript.pdf' do
    let(:book) { book_for('janval-glued-superscript.pdf', 'pt') }

    it 'separates a superscript marker glued to the year before it' do
      expect(spoken(book)).to include('no ano de 2010,')
      expect(spoken(book)).not_to include('20101')
      expect(references(book).map(&:id)).to include('1')
    end
  end

  describe 'b1-numbered-headings.pdf' do
    let(:book) { book_for('b1-numbered-headings.pdf', 'pt') }

    it 'reads numbered and lettered section titles as headings' do
      expect(headings(book)).to include(
        '1. O Ciclo das Políticas Públicas',
        '2. Modelos de Implementação de Políticas Públicas',
        '3. Importância do Processo de Implementação',
        'A. Modelo Top-down (De Cima para Baixo)',
        'B. Modelo Bottom-up (De Baixo para Cima)'
      )
    end

    it 'does not leave the section number hanging at the end of the paragraph before it' do
      expect(paragraph_texts(book)).to include(a_string_including('Sucede a tomada de decisão e antecede a avaliação.'))
      expect(sentences(book).map(&:text)).not_to include(a_string_matching(/\s\d\.\z/))
    end
  end

  describe 'adios-emphasis-lines.pdf' do
    let(:book) { book_for('adios-emphasis-lines.pdf', 'es') }

    it 'keeps an emphasised full sentence in the body' do
      expect(headings(book)).not_to include('Porque no están luchando contra la grasa.')
      expect(spoken(book)).to include('Porque no están luchando contra la grasa.')
    end

    it 'still recognises a short emphasised label as a heading' do
      expect(headings(book)).to include('La gran revelación')
      expect(items(book).grep(Audiobook::Section).size).to be <= 2
    end
  end
end
