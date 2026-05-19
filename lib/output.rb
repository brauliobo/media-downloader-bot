class Output
  # Builds a safe, human7 readable filename based on the metadata inside `info`.
  # Params:
  #   info   – SymMash with at least :title; :uploader is optional
  #   dir:   – directory where the file will be created (absolute or relative)
  #   ext:   – file extension without dot (e.g. 'mp4', 'srt')
  #   pos:   – optional numeric index to prefix (for playlists)
  # Returns String full path.
  MAX_LEN = 80

  def self.filename(info, dir:, ext:, pos: nil)
    base = info.title.to_s.dup
    base = format('%d %s', pos, base) if pos
    base << " by #{info.uploader.strip}" if info.uploader.present?
    base = base.first(MAX_LEN)
    base.gsub!("\"", '')   # Telegram rejects quotes
    base.gsub!('/', ', ')      # Avoid path separators
    suffix = ".#{ext}"
    filename = base.downcase.end_with?(suffix.downcase) ? base : "#{base}#{suffix}"
    File.join(dir, filename)
  end
end
