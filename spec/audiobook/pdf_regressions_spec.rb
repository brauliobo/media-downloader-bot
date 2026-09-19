require 'spec_helper'

# Each fixture is a page range lifted from a book a user sent to the bot, kept for the specific
# assembly defect it exposes: font metrics, page furniture, references, or heading classification.
RSpec.describe 'Audiobook assembly regressions' do
  def fixture(name) = File.expand_path("../fixtures/audiobook/#{name}", __dir__)

  def book_for(name, lang, **opts)
    Audiobook::Book.from_input(fixture(name), opts: SymMash.new(alang: lang, **opts), translate: false)
  end

  def items(book)     = book.pages.flat_map(&:items)
  def paragraphs(book) = items(book).grep(Audiobook::Paragraph)
  def paragraph_texts(book) = paragraphs(book).map { |para| para.sentences.map(&:text).join(' ') }
  def sentences(book) = paragraphs(book).flat_map(&:sentences)
  def headings(book)  = items(book).grep(Audiobook::Heading).map(&:text)
  def references(book) = sentences(book).flat_map(&:references)
  def spoken(book)    = item_texts(book).join("\n")
  def item_texts(book) = paragraph_texts(book) + headings(book)

  describe 'beginners-guide-urls.pdf' do
    it 'says where a link points instead of spelling it out' do
      spoken_text = spoken(book_for('beginners-guide-urls.pdf', 'en'))

      expect(spoken_text).to include('rumble.com', 'tv.gab.com')
      expect(spoken_text).not_to include('https://', 'vlm2ii')
    end
  end

  describe 'dispenza-summary-columns.pdf' do
    it 'reads a section the book sets in smaller type instead of taking it for margin notes' do
      expect(spoken(book_for('dispenza-summary-columns.pdf', 'pt'))).to include('Dominar o momento presente')
    end
  end

  describe 'fauci-patent-table.pdf' do
    let(:book) { book_for('fauci-patent-table.pdf', 'en') }

    it 'does not read a table out cell by cell' do
      expect(spoken(book)).not_to include('Priori')
    end

    # Judged by the page, the table took the page's prose down with it.
    it 'keeps the prose printed above the table' do
      expect(spoken(book)).to include('The following is the list of over 5,100 patents')
    end

    # 179 consecutive pages of patent rows is not an audiobook.
    it 'says a long table is there instead of reading it' do
      expect(spoken(book)).to match(/table of \d+ rows/i)
    end
  end

  describe 'apometria-colour-list.pdf' do
    it 'keeps a numbered list whose entries happen to line up with each other' do
      expect(spoken(book_for('apometria-colour-list.pdf', 'pt'))).to include('imobilização instantânea dos espíritos')
    end
  end

  describe 'fixing-gaze-back-index.pdf' do
    it 'stops before reading out the back-of-book index' do
      expect(item_texts(book_for('fixing-gaze-back-index.pdf', 'en'))).to be_empty
    end
  end

  describe 'nao-comecou-back-index.pdf' do
    it 'reads an index by its entries, not by the language its headings are in' do
      expect(item_texts(book_for('nao-comecou-back-index.pdf', 'pt'))).to be_empty
    end
  end

  describe 'salud-sorted-disease-list.pdf' do
    it 'keeps a chapter that happens to list its subject in alphabetical order' do
      spoken_text = spoken(book_for('salud-sorted-disease-list.pdf', 'es'))

      expect(spoken_text).to include('el dióxido de cloro es muy eficaz')
      expect(spoken_text).to include('Absceso').or include('Abceso')
    end
  end

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
    let(:everything) { book_for('kybalion-toc-leaders.pdf', 'en', includeall: true) }

    it 'leaves a table of contents out of the narration' do
      expect(spoken(book)).not_to include('The Hermetic Philosophy.')
    end

    it 'reads its entries without leader dots when asked for everything' do
      expect(paragraph_texts(everything)).to include(
        'Chapter I. The Hermetic Philosophy.', 'Chapter II. The Seven Hermetic Principles.'
      )
      expect(spoken(everything)).not_to match(/\.{4}|…{2}/)
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
    let(:everything) { book_for('mms-smallcaps-toc.pdf', 'pt', includeall: true) }

    it 'leaves the contents pages out of the narration' do
      expect(spoken(book)).not_to include('DESENVOLVIMENTO DE NOVOS PROTOCOLOS')
    end

    it 'joins small-capital runs back into their word when asked for everything' do
      expect(spoken(everything)).to include('DESENVOLVIMENTO DE NOVOS PROTOCOLOS')
      expect(spoken(everything)).not_to include('D ESENVOLVIMENTO')
      expect(spoken(everything)).not_to match(/\.{4}/)
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

    it 'keeps a catalogue record out of the narration and raises no reference from it' do
      expect(spoken(book)).not_to include('CDD', 'ISBN', 'Título.')
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
    let(:everything) { book_for('salud-contents-and-index.pdf', 'es', includeall: true) }

    it 'leaves a contents page and an index out of the narration' do
      expect(spoken(book)).not_to include('Protocolo C: como CDS', 'Cáncer colorrectal')
    end

    it 'reads each entry on its own without its page number when asked for everything' do
      expect(paragraph_texts(everything)).to include(
        'Protocolo B: como Básico, el equivalente al antiguo protocolo 1000',
        'Protocolo C: como CDS, el antiguo protocolo 101',
        'Cáncer colorrectal',
        'Cáncer gástrico o cáncer de estómago.'
      )
      expect(spoken(everything)).not_to match(/\b19\d\b/)
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

    # Run together, a stanza puts a capital in the middle of a sentence and reads as prose that
    # lost its punctuation.
    it 'reads a stanza one line at a time' do
      expect(sentences(book).map(&:text))
        .to include('A máquina assovia', 'Vomitando fumaça, e move-se, a ranger...')
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
  describe 'savin-mid-paragraph-sentences.pdf' do
    let(:book) { book_for('savin-mid-paragraph-sentences.pdf', 'en') }

    it 'keeps a paragraph together when a sentence ends at a line end' do
      para = paragraphs(book).find { |item| item.sentences.first.text.start_with?('As a country, one thing') }
      expect(para.sentences.size).to be >= 4
      expect(para.sentences.map(&:text).join(' ')).to include('And that is about who is actually behind the scene')
    end

    it 'still starts a paragraph where the page leaves a gap' do
      expect(paragraph_texts(book)).to include(a_string_starting_with('Is it always unique players'))
    end
  end

  describe 'reasons-numbered-labels.pdf' do
    let(:book) { book_for('reasons-numbered-labels.pdf', 'en') }

    it 'keeps a numbered label out of the block it names' do
      expect(item_texts(book)).to include('5. Time (how long to take the Protocols)', 'a. Herpes')
      expect(paragraph_texts(book)).to include(a_string_starting_with('The standard Protocol dosing time frame'))
    end

    it 'keeps a label at a page end out of the text that follows overleaf' do
      expect(item_texts(book)).to include('e. Compromised immune system')
      expect(paragraph_texts(book)).to include(a_string_starting_with('Every body has different issues'))
    end
  end

  describe 'nao-comecou-indent-paragraphs.pdf' do
    let(:book) { book_for('nao-comecou-indent-paragraphs.pdf', 'pt') }

    it 'opens a paragraph at an indented first line, not at every sentence' do
      para = paragraphs(book).find { |item| item.sentences.first.text.start_with?('Por um lado') }
      expect(para.sentences.size).to be >= 3
      expect(paragraphs(book).count { |item| item.sentences.size > 2 }).to be >= 2
    end
  end

  describe 'adios-one-line-paragraphs.pdf' do
    let(:book) { book_for('adios-one-line-paragraphs.pdf', 'es') }

    it 'still separates paragraphs a page sets one sentence at a time' do
      expect(paragraph_texts(book)).to include(
        'No sucede de un día para otro.', 'No aparece de repente.', 'Tu rostro amanece hinchado.'
      )
    end

    it 'carries a sentence past an ellipsis that a lowercase line continues' do
      expect(paragraph_texts(book)).to include(a_string_matching(/Y un cuerpo que vive en alerta\.\.\. no libera\./))
    end
  end
  describe 'path-cataloguing-record.pdf' do
    let(:book) { book_for('path-cataloguing-record.pdf', 'en') }

    it 'drops the rights notice and the cataloguing record' do
      expect(spoken(book)).not_to include('ISBN', 'p. cm.', 'dc22', 'Spirit writing', 'I. Title')
      expect(spoken(book)).not_to match(/©|All rights reserved/)
    end

    it 'keeps the dedication that shares the front matter' do
      expect(spoken(book)).to include('To my dear mother, with loving thanks')
    end
  end

  describe 'kybalion-rights-page.pdf' do
    let(:book) { book_for('kybalion-rights-page.pdf', 'en') }

    it 'raises no heading from an isbn or a publisher url' do
      expect(headings(book)).to all(satisfy { |text| !text.match?(/isbn|www\./i) })
      expect(spoken(book)).not_to match(/isbn|yogebooks\.com/i)
    end

    it 'keeps the dedication' do
      expect(spoken(book)).to include('To Hermes Trismegistus')
    end
  end
  describe 'mms-quick-guide-not-contents.pdf' do
    let(:book) { book_for('mms-quick-guide-not-contents.pdf', 'pt') }

    it 'reads a bulleted reference guide that names chapters and doses' do
      expect(spoken(book)).to include('Manutenção – entre 4 e 6 gotas por dia')
      expect(spoken(book)).to include('Prevenção da malária e do cancro')
      expect(paragraphs(book).size).to be >= 5
    end
  end
  describe 'nao-comecou-endnotes.pdf' do
    let(:book) { book_for('nao-comecou-endnotes.pdf', 'pt') }

    def reference_for(id) = references(book).find { |reference| reference.id == id }

    it 'reads a note from the back of the book where it is called' do
      expect(reference_for('2').sentences.map(&:text).join(' ')).to include('Com o que estamos aprendendo agora')
      expect(reference_for('33').sentences.map(&:text).join(' ')).to include('Max-Planck-Gesellschaft')
    end

    it 'numbers notes from one again under each chapter' do
      expect(reference_for('1').sentences.map(&:text).join(' ')).to include('CE Finch e JC Loehlin')
    end

    it 'does not read the list of notes a second time' do
      expect(spoken(book)).not_to include('Mary Sykes Wylie', 'Max-Planck-Gesellschaft')
      expect(headings(book)).not_to include('Notas')
    end
  end

  describe 'guia-page-notes-box.pdf' do
    let(:book) { book_for('guia-page-notes-box.pdf', 'pt') }

    it 'keeps a per-page notes box, which is not a list of endnotes' do
      expect(spoken(book)).to include('Notas')
      expect(spoken(book)).to include('Ao usar o suco de um limão fresco')
    end
  end
  describe 'matriz-part-title-page.pdf' do
    let(:book) { book_for('matriz-part-title-page.pdf', 'pt') }

    it 'does not run a part title into the heading that opens the next page' do
      expect(headings(book)).to include(
        'DESCOBRINDO A MATRIZ DIVINA: O MISTÉRIO QUE UNE TODAS AS COISAS',
        'O QUE EXISTE NO ESPAÇO EM VOLTA?'
      )
      expect(headings(book)).to all(satisfy { |text| text.split.size <= 12 })
    end
  end
  describe 'nao-comecou-orphan-quote.pdf' do
    let(:book) { book_for('nao-comecou-orphan-quote.pdf', 'pt') }

    it 'keeps a closing quote the text layer left on its own line with the sentence it closes' do
      expect(paragraph_texts(book)).to all(satisfy { |text| !text.start_with?('”') })
      expect(spoken(book)).to include('capacidades e potenciais. ”7 Vistos desta forma')
    end
  end

  describe 'guia-percent-as-marker.pdf' do
    let(:book) { book_for('guia-percent-as-marker.pdf', 'pt') }

    # The text layer extracts "22,4%" as "22,4" plus a raised "0", which looks like a call.
    it 'does not read a raised zero as a footnote call, since notes number from one' do
      expect(references(book).map(&:id)).not_to include('0')
      expect(spoken(book)).to include('clorito de sódio (a 22,40')
    end

    it 'reads a number glued to "página" as a page cross-reference, not as a call' do
      expect(references(book).map(&:id)).not_to include('278')
      expect(spoken(book)).to match(/na página ?278 para ter certeza/)
    end
  end

  describe 'janval-spaced-notes-title.pdf' do
    let(:book) { book_for('janval-spaced-notes-title.pdf', 'pt') }

    def reference_for(id) = references(book).find { |reference| reference.id == id }

    # The notes title is letter-spaced and its entries are numbered without a period, under a
    # per-chapter label set in a larger font.
    it 'recognises the notes section at the back instead of reading it as body text' do
      expect(spoken(book)).not_to include('Notas Explicativa')
    end

    it 'gives a call the note listed under its chapter label' do
      expect(reference_for('2').sentences.map(&:text).join(' ')).to include('Cultura Demodhármica')
      expect(references(book).select { |reference| reference.sentences.any? }).not_to be_empty
    end
  end

  describe 'hooks-chapter-end-notes.pdf' do
    let(:book) { book_for('hooks-chapter-end-notes.pdf', 'pt') }

    # This book gathers its notes at the end of a chapter, so a note never shares a page with its call.
    it 'binds a note printed pages after the call it answers' do
      reference = references(book).find { |item| item.id == '2' }
      expect(reference.sentences.map(&:text).join(' ')).to match(/Como te amo/)
    end
  end

  describe 'apometria-bullet-column.pdf' do
    let(:everything) { book_for('apometria-bullet-column.pdf', 'pt', includeall: true) }

    # Every bullet of this contents list landed in one block at the left margin, never next to its entry.
    it 'never speaks a bullet glyph' do
      expect(item_texts(everything)).not_to include('•')
      expect(spoken(everything)).not_to include('•')
    end

    it 'reads each contents entry as its own item' do
      expect(item_texts(everything)).to include(
        'Bibliografia', 'Cadastre a Sua Casa Apométrica', 'Casas Apométricas'
      )
    end
  end

  describe 'milagroso-running-foot.pdf' do
    let(:book) { book_for('milagroso-running-foot.pdf', 'es') }

    # Every page of this book ends with the same eleven-word footer selling the product. Page
    # furniture used to be recognised only up to eight words, so the footer reached the assembly
    # and stood between the two halves of the paragraph that ran across the page break.
    it 'joins the paragraph the footer used to stand in the middle of' do
      expect(spoken(book)).to include('Había otro socio que se suponía llegaría muy pronto')
    end

    it 'never speaks the footer' do
      expect(spoken(book)).not_to include('Ver capitulo')
    end
  end

  describe 'milagroso-foot-spoken.pdf' do
    let(:book) { book_for('milagroso-foot-spoken.pdf', 'es') }

    # The same plea repeats at the foot of page after page; it is furniture, not narration.
    it 'never speaks the repeated footer' do
      expect(spoken(book)).not_to include('platique a sus amigos')
    end
  end

  describe 'hooks-sumario-no-folios.pdf' do
    let(:book) { book_for('hooks-sumario-no-folios.pdf', 'pt') }
    let(:everything) { book_for('hooks-sumario-no-folios.pdf', 'pt', includeall: true) }

    # This contents page names itself "SUMÁRIO" and prints no page numbers beside its entries,
    # so the entries had no folio to prove themselves by and the whole list was read out.
    it 'leaves a contents page that names itself out of the narration' do
      expect(spoken(book)).not_to include('Clareza: pôr o amor em palavras')
      expect(spoken(book)).not_to include('Justiça: lições de amor na infância')
    end

    it 'still reads its entries when asked for everything' do
      expect(spoken(everything)).to include('Clareza: pôr o amor em palavras')
    end
  end

  describe 'whatdoctors-ocr-contents.pdf' do
    let(:book) { book_for('whatdoctors-ocr-contents.pdf', 'en') }

    # A scan whose leader dots came through as "oo" and "ao:" left its contents pages looking
    # like prose: no leaders, no chapter labels, and entries that are bare titles.
    it 'leaves the scanned contents pages out of the narration' do
      expect(spoken(book)).not_to include('Primum Non Nocere')
      expect(spoken(book)).not_to include('The Patient that Changed my Life')
    end
  end

  describe 'beginners-guide-dosage-table.pdf' do
    let(:book) { book_for('beginners-guide-dosage-table.pdf', 'en') }

    # Prose above, a four-column protocol table below. Judged as a page it was neither: the rows
    # read as a contents list and the whole page went silent, prose and all.
    it 'keeps the prose a table shares its page with' do
      expect(spoken(book)).to include('I recommend to anyone that they learn how to measure and use both')
    end

    it 'reads a table row by row, each cell under its own heading' do
      expect(spoken(book)).to match(/B: Basic.*3 drops MMS1.*8 doses per day for 21 days/m)
    end

    it 'does not read a column down the page' do
      expect(spoken(book)).not_to match(/3 drops MMS1\W+10 ml CDS per 1 liter water/m)
    end
  end

  describe 'guia-dosage-table.pdf' do
    let(:book) { book_for('guia-dosage-table.pdf', 'pt') }

    # One table over a page break: the first half scored above the page threshold and went
    # silent, the second half below it and was read out a column at a time.
    it 'reads both halves of a table that runs over a page break' do
      expect(spoken(book)).to match(/Peso do Animal.*1 - 2 libras/m)
      expect(spoken(book)).to match(/1500 - 2300 libras/m)
    end
  end

  describe 'dispenza-endnote-section.pdf' do
    let(:book) { book_for('dispenza-endnote-section.pdf', 'pt') }

    # "Notas" stands alone on its page and the entries start on the next, two to a page. The
    # section was looked for one page ahead and needed three entries, so it was never found.
    it 'binds a note whose section title stands alone on its page' do
      expect(references(book).map(&:id)).to include('1')
      expect(references(book).flat_map(&:sentences).map(&:text).join(' '))
        .to include('Global Union of Scientists for Peace')
    end
  end

  describe 'hollis-nested-blocks.epub notes' do
    let(:book) { book_for('hollis-nested-blocks.epub', 'en') }

    # This book prints the marker on one line and the note on the next, so a note took the
    # number of the note after it for its text.
    it 'does not bind a note to the number of the next one' do
      bound = references(book).map { |ref| ref.sentences.map(&:text).join(' ') }.reject(&:empty?)

      expect(bound).not_to be_empty
      expect(bound).to all(match(/\p{L}/))
    end
  end
end
