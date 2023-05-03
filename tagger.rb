require 'taglib'

class Tagger

  def self.add_cover fn, fthumb
    # FIXME: only works for audio, it removes other tags from video
    cmd = "kid3-cli"
    cmd << " -c \"cd #{Sh.escape File.dirname fn}\"  -c \"select #{Sh.escape File.basename fn}\""
    cmd << " -c \"set picture:#{Sh.escape File.basename fthumb} COVER\""
    cmd << " -c save"
    Sh.run cmd
  end

  def self.copy fn_in, fn_out
    cmd = "kid3-cli" 
    cmd << " -c \"cd #{Sh.escape File.dirname fn_in}\"  -c \"select #{Sh.escape File.basename fn_in}\""
    cmd << " -c copy"
    cmd << " -c \"cd #{Sh.escape File.dirname fn_out}\" -c \"select #{Sh.escape File.basename fn_out}\""
    cmd << " -c paste -c save"
    Sh.run cmd
  end

  def self.tag fn, info
    TagLib::FileRef.open fn do |f|
      return if f&.tag.nil?
      f.tag.title   = info.title
      f.tag.artist  = info.uploader
      f.tag.comment = info.info.original_url
      f.save
    end
  end

  protected

end
