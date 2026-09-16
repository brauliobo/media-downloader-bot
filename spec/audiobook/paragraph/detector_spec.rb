require 'spec_helper'

RSpec.describe Audiobook::Paragraph::Detector do
  def line(text, size: 12, page: 1, x: 50, top: 4, bottom: 4, **style)
    Audiobook::Line.new(
      text, font_size: size, page_number: page, x_position: x,
      top_spacing: top, bottom_spacing: bottom, **style
    )
  end

  def items_from(*lines)
    roles = Audiobook::FontRoles.from_lines(lines)
    Audiobook::FontRoles.use(roles) { described_class.discover_from_lines(lines) }.map { |entry| entry[:item] }
  end

  it 'folds an oversized opening letter into the word it starts' do
    items = items_from(
      line('W', size: 66, x: 52),
      line('e take great pleasure in presenting this little work to our readers.', x: 102),
      line('There has been so little written upon this subject in the many works.'),
      line('Our intent is not to erect a new temple but to hand over a master key.')
    )

    expect(items.grep(Audiobook::Heading)).to be_empty
    expect(items.first.sentences.first.text).to start_with('We take great pleasure')
  end

  it 'reads a line fenced by blank space as a heading' do
    items = items_from(
      line('Este resumo aborda os conceitos fundamentais do ciclo das políticas.', top: 4, bottom: 18),
      line('1. O Ciclo das Políticas Públicas', top: 18, bottom: 18),
      line('Definição: Um processo sequencial que o Estado utiliza para responder.', top: 18, bottom: 4),
      line('Estágios do ciclo deliberativo com foco na fase de implementação.'),
      line('Natureza do ciclo, embora sequencial, pode ocorrer de forma não linear.')
    )

    expect(items.grep(Audiobook::Heading).map(&:text)).to include('1. O Ciclo das Políticas Públicas')
    expect(items.grep(Audiobook::Paragraph).map { |item| item.sentences.first.text })
      .to include(a_string_starting_with('Definição:'))
  end

  it 'keeps ordinary paragraph spacing out of the heading path' do
    items = items_from(
      line('A primeira frase do parágrafo que continua logo abaixo sem pausa.', top: 4, bottom: 4),
      line('Uma linha curta e solta.', top: 4, bottom: 4),
      line('Outra frase do mesmo bloco de texto corrido com várias palavras.', top: 4, bottom: 4)
    )

    expect(items.grep(Audiobook::Heading)).to be_empty
  end

  it 'rejoins a word split by a soft hyphen at the line break' do
    items = items_from(
      line("Su respuesta fue sim­"),
      line('ple, me dijo que lo intentara sin más explicación científica exacta.')
    )

    expect(items.first.sentences.map(&:text).join(' ')).to include('fue simple, me dijo')
  end
end
