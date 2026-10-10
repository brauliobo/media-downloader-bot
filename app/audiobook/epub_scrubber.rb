require 'fileutils'
require 'tmpdir'

module Audiobook
  # Removes the paragraphs a distributor stamps on an EPUB (e.g. "Book made for someone@mail.com"),
  # so they are neither read nor narrated.
  class EpubScrubber
    STAMP  = /Book made for \S+@\S+/
    MARKUP = '**/*.{xhtml,html,htm,opf,ncx}'.freeze

    # Returns how many paragraphs were removed; dest is only written when there was any.
    def self.call(src, dest, stamp: STAMP) = new(stamp).call(src, dest)

    def initialize(stamp = STAMP)
      @stamp     = stamp
      @paragraph = %r{[ \t]*<p\b[^>]*>[^<]*#{stamp}[^<]*</p>[ \t]*\r?\n?}
    end

    def call(src, dest)
      Dir.mktmpdir('epub-scrub') do |dir|
        run 'unzip', %W[unzip -q -o #{File.expand_path(src)} -d #{dir}]
        removed = markup(dir).sum { |file| scrub(file) }
        raise "stamp still present in #{src}" if markup(dir).any? { |file| File.read(file).match?(@stamp) }

        pack(dir, File.expand_path(dest)) if removed.positive?
        removed
      end
    end

    private

    def markup(dir) = Dir.glob(File.join(dir, MARKUP))

    def scrub(file)
      text  = File.read(file)
      count = text.scan(@paragraph).size
      File.write(file, text.gsub(@paragraph, '')) if count.positive?
      count
    end

    # The mimetype entry must come first and stored, or readers reject the EPUB.
    def pack(dir, dest)
      FileUtils.rm_f dest
      run 'zip', %W[zip -q -X0 #{dest} mimetype], chdir: dir
      run 'zip', %W[zip -q -X9 -D -r #{dest} . -x mimetype], chdir: dir
    end

    def run(label, cmd, **opts)
      _, err, status = Sh.run(cmd, **opts)
      Sh.assert_success!(label, err, status: status)
    end
  end
end
