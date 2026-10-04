require 'digest'
require 'json'
require 'nokogiri'

module Ewprs
  class SlokaLanguages
    PARAGRAPH = %r{<p\b(?=[^>]*\bclass\s*=\s*["']?Para_Sloka\b)[^>]*>.*?</p\s*>}min
    OPENING   = /\A<p\b[^>]*>/min
    LANG      = /\s+lang\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/in

    def initialize(manifest:)
      @manifest = JSON.parse(File.read(manifest))
    end

    def annotate_tree(root, write: true)
      stats = {files: 0, changed_files: 0, paragraphs: 0, languages: Hash.new(0)}
      Dir.glob(File.join(File.expand_path(root), '**/*.html')).sort.each do |path|
        result = annotate(File.binread(path), path: path)
        next if result[:paragraphs].zero?

        stats[:files] += 1
        stats[:paragraphs] += result[:paragraphs]
        result[:languages].each { |language, count| stats[:languages][language] += count }
        next unless result[:changed]

        stats[:changed_files] += 1
        File.binwrite(path, result[:html]) if write
      end
      stats[:languages] = stats[:languages].sort.to_h
      stats
    end

    def annotate(html, path: nil)
      paragraphs = 0
      languages = Hash.new(0)
      annotated = html.gsub(PARAGRAPH) do |paragraph|
        paragraphs += 1
        digest = self.class.digest(paragraph)
        language = @manifest[digest] || raise("unclassified Para_Sloka in #{path || 'HTML'}: #{digest}")
        languages[language] += 1
        opening = paragraph.match(OPENING).to_s
        tagged = opening.sub(LANG, '').sub(/>\z/, " lang=\"#{language}\">")
        paragraph.sub(OPENING, tagged)
      end
      {html: annotated, changed: annotated != html, paragraphs: paragraphs, languages: languages}
    end

    def self.digest(paragraph)
      fragment = paragraph.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
      node = Nokogiri::HTML5.fragment(fragment).at_css('p')
      node.css('sup,script,style').remove
      node.css('br').each { |br| br.replace("\n") }
      text = node.text.gsub(/\s+/, ' ').strip.unicode_normalize(:nfc)
      Digest::SHA256.hexdigest(text)
    end
  end
end
