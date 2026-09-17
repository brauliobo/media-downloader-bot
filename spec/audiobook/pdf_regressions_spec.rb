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
  def spoken(book)    = item_texts(book).join("\n")
  def item_texts(book) = paragraph_texts(book) + headings(book)

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

  describe 'guia-split-baseline.pdf' do
    let(:book) { book_for('guia-split-baseline.pdf', 'pt') }

    it 'joins a justified line that the text layer split into baseline fragments' do
      expect(spoken(book)).to include('possivelmente começar a ver resultados positivoslogo amanhã.')
      expect(headings(book)).not_to include('começar a ver')
    end
  end

  describe 'guia-copyright-year.pdf' do
    let(:book) { book_for('guia-copyright-year.pdf', 'pt') }

    it 'does not turn a bare year into a reference' do
      expect(references(book)).to be_empty
    end
  end

  describe 'salud-contents-and-index.pdf' do
    let(:book) { book_for('salud-contents-and-index.pdf', 'es') }

    it 'reads each contents entry on its own without its page number' do
      expect(paragraph_texts(book)).to include(
        'Protocolo B: como Básico, el equivalente al antiguo protocolo 1000',
        'Protocolo C: como CDS, el antiguo protocolo 101',
        'Cáncer colorrectal',
        'Cáncer gástrico o cáncer de estómago.'
      )
      expect(spoken(book)).not_to match(/\b19\d\b/)
    end

    it 'keeps contents entries out of the outline and the reference machinery' do
      expect(headings(book)).to be_empty
      expect(references(book)).to be_empty
    end
  end

  describe 'salud-numbered-and-long-lists.pdf' do
    let(:book) { book_for('salud-numbered-and-long-lists.pdf', 'es') }

    it 'reads each numbered item as its own paragraph' do
      expect(paragraph_texts(book)).to include(
        '1. Introducción y explicación simple y fácil para que todo el mundo, aunque no sea profesional de la salud, lo entienda.',
        '2. Testimonios de casos y de recuperación de las enfermedades, por orden de la A hasta la Z, con el protocolo que usaron.'
      )
      expect(sentences(book).map(&:text)).not_to include(a_string_matching(/\s\d\.\z/))
    end

    it 'reads a long comma list in a few long chunks instead of one item per pause' do
      list = paragraphs(book).find { |para| para.sentences.first.text.start_with?('Abscesos dentales') }

      expect(list.sentences.size).to be_between(2, 4)
      expect(list.sentences.map { |sentence| sentence.text.length }).to all(be <= Audiobook::Paragraph::Factory::MAX_SENTENCE_CHARS)
    end
  end

  describe 'reasons-product-names-lettered-list.pdf' do
    let(:book) { book_for('reasons-product-names-lettered-list.pdf', 'en') }

    it 'keeps a digit that names a product out of the references' do
      expect(spoken(book)).to include('The basic MMS1 protocol is 3 drops an hour')
      expect(references(book)).to be_empty
    end

    it 'reads lettered list items separately after their lead-in' do
      expect(paragraph_texts(book)).to include('a. Raw milk', 'b. Raw butter', 'c. Raw cheese')
      expect(headings(book)).not_to include(a_string_starting_with('We recommend'))
    end
  end

  describe 'janval-bold-emphasis-run.pdf' do
    let(:book) { book_for('janval-bold-emphasis-run.pdf', 'pt') }

    it 'keeps a bold run inside the sentence it emphasises' do
      expect(paragraph_texts(book)).to include(
        a_string_including('era o mesmo que Javé havia sonhado para a humanidade, antes do despertar de Pandora e de Eva')
      )
      expect(headings(book)).not_to include(a_string_matching(/\A\p{Ll}/))
    end
  end

  describe 'path-bold-italic-lead.pdf' do
    let(:book) { book_for('path-bold-italic-lead.pdf', 'en') }

    it 'keeps a bold-italic opening line with the paragraph it starts' do
      expect(paragraph_texts(book)).to include(
        'The period from 1987 to 2012 has been foreseen by great sages in many ages as the turning point in a very powerful cycle of human development.'
      )
      expect(headings(book)).to be_empty
    end
  end

  describe 'tragedia-verse-stanza.pdf' do
    let(:book) { book_for('tragedia-verse-stanza.pdf', 'pt') }

    it 'does not read a stanza as a heading because its first line is short' do
      expect(headings(book)).not_to include(a_string_starting_with('Doce terra'))
      expect(paragraph_texts(book)).to include(a_string_including('Doce terra bendita, Coberta de planícies assombrosas'))
    end
  end

  describe 'adios-ellipsis-lead.pdf' do
    let(:book) { book_for('adios-ellipsis-lead.pdf', 'es') }

    it 'keeps an ellipsis lead-in with the sentence it opens' do
      expect(paragraph_texts(book)).to include('De hecho… es una señal de que las bacterias intestinales están trabajando.')
      expect(headings(book)).not_to include('De hecho…')
    end
  end

  describe 'nao-comecou-glued-markers.pdf' do
    let(:book) { book_for('nao-comecou-glued-markers.pdf', 'pt') }

    it 'takes a marker off a closing quote the text layer glued it to' do
      expect(spoken(book)).to include('ou mesmo com úlceras.”')
      expect(spoken(book)).not_to include('úlceras.”10')
      expect(references(book).map(&:id)).to include('10', '11', '13')
    end
  end

  describe 'mms-bullet-baseline.pdf' do
    let(:book) { book_for('mms-bullet-baseline.pdf', 'pt') }

    it 'does not mistake body digits for markers when a bullet lowers the line box' do
      expect(spoken(book)).to include('com 8 gotas por copo', 'utilize 10 gotas por 30 ml')
      expect(references(book)).to be_empty
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
  describe 'kybalion-justified-word-gaps.pdf' do
    let(:book) { book_for('kybalion-justified-word-gaps.pdf', 'en') }

    it 'keeps the spaces of a tightly justified line' do
      expect(spoken(book)).to include('So, the Hermetic Teachings do not preach the unsubstantiality')
      expect(spoken(book)).not_to match(/\p{L}{30,}/)
    end
  end

  describe 'mms-per-word-blocks.pdf' do
    let(:book) { book_for('mms-per-word-blocks.pdf', 'pt') }

    it 'rejoins a justified line whose words each landed in their own block' do
      expect(spoken(book)).to include('dias, estou certo de que a minha hepatite C desapareceu')
      expect(headings(book)).to all(satisfy { |text| !text.include?('estou certo de que') })
    end
  end

  describe 'kybalion-sparse-folio-page.pdf' do
    let(:book) { book_for('kybalion-sparse-folio-page.pdf', 'en') }

    it 'drops the folio and running head of a page that holds nothing else' do
      expect(item_texts(book)).not_to include('viii', 'The Kybalion')
    end
  end

  describe 'guia-reflowed-folios.pdf' do
    let(:book) { book_for('guia-reflowed-folios.pdf', 'pt') }

    it 'drops roman folios reflowed into the middle of the page' do
      expect(item_texts(book)).not_to include('VI', 'VII', 'VIII', 'IX')
    end

    it 'drops a running head that alternates between pages' do
      expect(spoken(book)).not_to include('MMS Health Recovery Guldebook')
      expect(spoken(book)).to include('Agradecimentos')
    end
  end

  describe 'salud-margin-noise.pdf' do
    let(:book) { book_for('salud-margin-noise.pdf', 'es') }

    it 'drops print marks set far below body size outside the column' do
      expect(item_texts(book)).to all(satisfy { |text| !text.match?(/\A[^\p{L}]*S\u00cd/) })
      expect(spoken(book)).to include('Abreviaturas')
    end
  end

  describe 'tragedia-indented-verse.pdf' do
    let(:book) { book_for('tragedia-indented-verse.pdf', 'pt') }

    it 'reads a stanza as one block instead of a heading per line' do
      expect(headings(book)).to contain_exactly('O BATISMO DE SANGUE')
      expect(spoken(book)).to include('Vai-se sumindo o trem, quando na plataforma Se levanta, orgulhoso')
    end

    it 'keeps an indented verse line that sits at the page edge' do
      expect(spoken(book)).to include('à luz que se bifurca Em réstias infinitas Das barracas')
    end
  end
  describe 'salud-abbreviation-line-end.pdf' do
    let(:book) { book_for('salud-abbreviation-line-end.pdf', 'es') }

    it 'carries a sentence past an honorific that ends the line' do
      expect(spoken(book)).to include('Dra. Antje Oswald, Dr. Angel Escudero')
      expect(paragraph_texts(book)).to all(satisfy { |text| !text.match?(/\bDr\.\z/) })
    end
  end

  describe 'savin-initials-line-end.pdf' do
    let(:book) { book_for('savin-initials-line-end.pdf', 'en') }

    it 'keeps an initial attached to the name it abbreviates' do
      expect(spoken(book)).to include('into the U. S. We are systematically')
      expect(sentences(book).map(&:text)).not_to include('S.')
    end
  end

  describe 'nao-comecou-orphan-dropcap.pdf' do
    let(:book) { book_for('nao-comecou-orphan-dropcap.pdf', 'pt') }

    it 'drops a drop cap whose word was replaced in translation' do
      expect(item_texts(book)).not_to include('T')
      expect(paragraph_texts(book).join(' ')).to include('A história que você compartilha com sua família')
    end

    it 'reads an attribution as prose, not as a heading' do
      expect(headings(book)).to all(satisfy { |text| !text.start_with?('—') })
      expect(spoken(book)).to include('—Carl Jung, Memórias, Sonhos, Reflexões')
    end
  end

  describe 'apometria-centered-attribution.pdf' do
    let(:book) { book_for('apometria-centered-attribution.pdf', 'pt') }

    it 'does not raise a heading from a lowercase line at body size' do
      expect(headings(book)).not_to include('no IV Encontro Regional de Apometria - Lages - SC')
      expect(spoken(book)).to include('no IV Encontro Regional de Apometria - Lages - SC')
    end
  end

  describe 'salud-margin-noise.pdf definition list' do
    let(:book) { book_for('salud-margin-noise.pdf', 'es') }

    it 'starts a block at each definition instead of running them together' do
      entries = paragraph_texts(book).select { |text| text.match?(/\A(?:CD|CDS|CDH|DMSO|MMS2|NaCI)\b/) }
      expect(entries.size).to be >= 3
    end
  end
  describe 'salud-unmapped-bullets.pdf' do
    let(:book) { book_for('salud-unmapped-bullets.pdf', 'es') }

    it 'starts a block at each bullet the text layer turned into a zero' do
      items = paragraph_texts(book).select { |text| text.start_with?('No se debe', 'No se recomienda') }
      expect(items.size).to eq(3)
    end

    it 'does not speak the bullet' do
      expect(spoken(book)).not_to match(/(?:\A|\n)[0oO°]\s/)
      expect(spoken(book)).to include('No se debe mezclar y aplicar el DMSO')
    end
  end

  describe 'reasons-bullet-glyphs.pdf' do
    let(:book) { book_for('reasons-bullet-glyphs.pdf', 'en') }

    it 'keeps a bullet glyph out of the narration' do
      expect(spoken(book)).not_to include('►')
      expect(spoken(book)).to include('MMS1 is activated MMS.')
    end
  end
end
