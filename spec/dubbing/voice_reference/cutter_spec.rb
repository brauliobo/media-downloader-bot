require 'rails_helper'

RSpec.describe Dubbing::VoiceReference::Cutter do
  let(:dir)   { Dir.mktmpdir('cutter-spec-') }
  # silence 0.0-0.5, tone 0.5-1.5, silence 1.5-1.9, tone 1.9-2.9, silence 2.9-3.4
  let(:audio) { File.join(dir, 'speech.wav') }

  before do
    pieces = [[:silence, 0.5], [:tone, 1.0], [:silence, 0.4], [:tone, 1.0], [:silence, 0.5]]
    inputs = pieces.map { |kind, seconds| kind == :tone ? "sine=f=220:r=22050:d=#{seconds}" : "anullsrc=r=22050:cl=mono:d=#{seconds}" }
    command = ['ffmpeg', '-v', 'error', '-y', *inputs.flat_map { |input| ['-f', 'lavfi', '-i', input] },
               '-filter_complex', "#{pieces.each_index.map { |idx| "[#{idx}:a]" }.join}concat=n=#{pieces.size}:v=0:a=1", audio]
    _, stderr, status = Open3.capture3(*command)
    raise stderr unless status.success?
  end

  after { FileUtils.remove_entry(dir) }

  def selection(start, finish, before: 0.25, after: 0.25)
    Dubbing::VoiceReference::Selection.new(start: start, duration: finish - start, text: 'Sentence.', before: before, after: after)
  end

  def cut(selection) = described_class.new.call(audio, selection, dir: dir)

  it 'moves a cut that lands inside a word out into the silence before and after it' do
    cut = cut(selection(0.55, 1.45))

    expect(cut.start).to be_between(0.3, 0.5)
    expect(cut.start + cut.duration).to be_between(1.5, 1.7)
    expect(cut.clean).to be(true)
    expect([cut.before, cut.after]).to eq([0.0, 0.0])
  end

  it 'keeps a cut that is already in silence where it is' do
    cut = cut(selection(0.4, 1.6))

    expect(cut.start).to eq(0.4)
    expect(cut.start + cut.duration).to be_within(1e-9).of(1.6)
    expect(cut.clean).to be(true)
  end

  it 'never cuts into the sentence, so no sound is lost' do
    cut = cut(selection(0.7, 1.3))

    expect(cut.start).to be <= 0.7
    expect(cut.start + cut.duration).to be >= 1.3
  end

  it 'reports a cut in the middle of speech, with no room to move, as not clean' do
    expect(cut(selection(0.7, 1.3, before: 0.0, after: 0.0)).clean).to be(false)
  end

  it 'finds silence between two sentences without crossing into the next word' do
    cut = cut(selection(0.55, 1.45, before: 0.25, after: 0.4))

    expect(cut.start + cut.duration).to be < 1.9
  end

  it 'does not leave the temporary cut audio behind' do
    cut(selection(0.55, 1.45))

    expect(Dir.children(dir)).to eq(['speech.wav'])
  end
end
