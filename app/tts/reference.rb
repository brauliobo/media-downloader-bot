class TTS
  # A voice for the backend to clone: audio of someone speaking and the words said in it.
  # It is recorded (extracted from real speech) or an Anchor (made up by the backend).
  Reference = Data.define(:path, :text) do
    def tts_options = {speaker_wav: path, ref_text: text}
  end
end
