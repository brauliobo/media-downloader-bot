module Replay
  # The hashtags of a book posted without them because their generation failed (the proxy was rate limited, the model refused),
  # generated again from the yml posted with the book. What went wrong is raised.
  class Retag
    def initialize(manager) = @manager = manager

    def call(item)
      path = PostedYml.new(@manager).path(item) or raise 'no yml was posted with the book'
      opts = SymMash.new(hashtags: true)
      Audiobook.hashtags!(Audiobook::Book.from_yaml(path, opts: opts), opts).presence or raise 'no hashtags came out of the book'
    end
  end
end
