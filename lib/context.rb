class Context
  # Request
  attr_accessor :msg, :line, :url, :opts, :session
  
  # Execution
  attr_accessor :dir, :tmp
  
  # Status
  attr_accessor :st, :stl

  def initialize(url: nil, opts: nil, dir: nil, tmp: nil, st: nil, session: nil, msg: nil, stl: nil, line: nil)
    @url = url
    @opts = opts
    @dir = dir
    @tmp = tmp
    @st = st
    @session = session
    @msg = msg
    @stl = stl
    @line = line
  end
end
