require 'spec_helper'

RSpec.describe 'Page paragraph cross-page merge' do
  def fixture_path(name) = File.expand_path("../fixtures/#{name}", __dir__)
  def paragraph_text(para)
    para.sentences.map(&:text).join(' ').gsub(/\s+/, ' ').strip
  end

  PAGE_1_TO_2_PARAGRAPH = 'A idéia de que o bem-estar de um reino depende da virilidade ou do poder de seu governante é bastante comum, especialmente entre os povos primitivos. Nas áreas menos civilizadas do mundo ainda existem sociedades onde o rei é executado quando não mais pode gerar descendência. Simplesmente o matam em meio a cerimônias, algumas vezes vagarosamente, outras, de formas horríveis. A crença é a de que o reino não vai prosperar sob um rei fraco ou enfermiço.'
  PAGE_2_TO_3_PARAGRAPH = 'Todo adolescente recebe sua ferida-Rei-Pescador. Não fosse assim, jamais conseguiria a consciência. Se você quiser compreender um jovem que já passou pela puberdade é preciso que isso fique bem claro. Virtualmente, todo menino tem as feridas do Rei Pescador. É o que a Igreja chama de felix culpa, ou seja, a queda feliz que conduz o indivíduo a seu processo de redenção. É a queda do Jardim do Éden, ou seja, a evolução da consciência ingênua à total consciência do self.'
  PAGE_3_TO_4_PARAGRAPH = 'O mito também nos diz que o rei foi ferido na coxa, o que nos faz lembrar a passagem bíblica sobre Jacó lutando com o Anjo. Jacó é ferido na coxa. O toque de algo transpessoal - um anjo ou Cristo na representação do peixe - deixa uma terrível ferida, que grita incessantemente por redenção. O ferimento na coxa significa que o homem foi atingido na sua capacidade de gerar, na sua habilidade para relacionar-se.'

  it 'merges the last paragraph of page 1 with its continuation on page 2' do
    book = Audiobook::Book.from_input(fixture_path('page-paragraphs-merge.pdf'))
    page1 = book.pages[0]
    last_para_p1 = page1.items.grep(Audiobook::Paragraph).last
    expect(paragraph_text(last_para_p1)).to eq(PAGE_1_TO_2_PARAGRAPH)
  end

  it 'merges the last paragraph of page 2 with its continuation on page 3' do
    book = Audiobook::Book.from_input(fixture_path('page-paragraphs-merge.pdf'))
    page2 = book.pages[1]
    last_para_p2 = page2.items.grep(Audiobook::Paragraph).last
    expect(paragraph_text(last_para_p2)).to eq(PAGE_2_TO_3_PARAGRAPH)
  end

  it 'merges the last paragraph of page 3 with its continuation on page 4' do
    book = Audiobook::Book.from_input(fixture_path('page-paragraphs-merge.pdf'))
    page3 = book.pages[2]
    last_para_p3 = page3.items.grep(Audiobook::Paragraph).last
    expect(paragraph_text(last_para_p3)).to eq(PAGE_3_TO_4_PARAGRAPH)
  end

  it 'does not create headings from numeric markers and attaches refs to correct sentences' do
    book = Audiobook::Book.from_input(fixture_path('page-paragraphs-merge.pdf'))
    page1 = book.pages[0]
    # Ensure there is no heading like "1 2"
    expect(page1.items.grep(Audiobook::Heading).map { |h| h.text.to_s }).not_to include('1 2')

    # Find the paragraph around Chrétien line and ensure references include 1,2,3 and are not nested
    para = page1.items.grep(Audiobook::Paragraph).find do |p|
      p.sentences.any? { |s| s.text.include?('Wolfram von Eschenbach') }
    end
    expect(para).not_to be_nil
    # The sentence ending with "Chrétien de Troyes." should carry ref 1
    troyes_sent = para.sentences.find { |s| s.text.strip.end_with?('Chrétien de Troyes.') }
    expect(troyes_sent).not_to be_nil
    expect(Array(troyes_sent.references).map(&:id)).to include('1')

    # The sentence containing Eschenbach should carry refs 2 and 3
    esch_sent = para.sentences.find { |s| s.text.include?('Eschenbach') }
    expect(esch_sent).not_to be_nil
    expect(Array(esch_sent.references).map(&:id)).to include('2', '3')
  end
end


