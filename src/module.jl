using Tokenize

# –––––––––––––––
# Some file utils
# –––––––––––––––

function readdir′(dir)
  try
    readdir(dir)
  catch e
    String[]
  end
end

isdir′(f) = try isdir(f) catch e false end
isfile′(f) = try isfile(f) catch e false end

files(dir) =
  @>> dir readdir′ map!(f->joinpath(dir, f)) filter!(isfile′)

dirs(dir) =
  @>> dir readdir′ filter!(f->!startswith(f, ".")) map!(f->joinpath(dir, f)) filter!(isdir′)

jl_files(dir::AbstractString) = @>> dir files filter!(f->endswith(f, ".jl"))

function jl_files(set)
  files = Set{String}()
  for dir in set, file in jl_files(dir)
    push!(files, file)
  end
  return files
end

"""
Takes a start directory and returns a set of nearby directories.
"""
# Recursion + Mutable State = Job Security
function dirsnearby(dir; descend = 1, ascend = 1, set = Set{String}())
  push!(set, dir)
  if descend > 0
    for down in dirs(dir)
      if !(down in set)
        push!(set, down)
        descend > 1 && dirsnearby(down, descend = descend-1, ascend = 0, set = set)
      end
    end
  end
  ascend > 0 && dirsnearby(dirname(dir), descend = descend, ascend = ascend-1, set = set)
  return set
end

# ––––––––––––––
# The Good Stuff
# ––––––––––––––
SCOPE_STARTERS = [Tokenize.Tokens.BEGIN,
                  Tokenize.Tokens.WHILE,
                  Tokenize.Tokens.IF,
                  Tokenize.Tokens.FOR,
                  Tokenize.Tokens.TRY,
                  Tokenize.Tokens.FUNCTION,
                  Tokenize.Tokens.MACRO,
                  Tokenize.Tokens.LET,
                  Tokenize.Tokens.ABSTRACT,
                  Tokenize.Tokens.TYPE,
                  Tokenize.Tokens.BITSTYPE,
                  Tokenize.Tokens.IMMUTABLE,
                  Tokenize.Tokens.DO,
                  Tokenize.Tokens.QUOTE,
                  Tokenize.Tokens.MODULE,
                  Tokenize.Tokens.BAREMODULE
                 ]

"""
Takes Julia source code and a line number, gives back the string name
of the module at that line.
"""
function codemodule(code, line)
  stack = String[]
  # count all unterminated block openers
  n_openers = 0
  unfinished_bracket = false
  
  ts = tokenize(code)

  for t in ts

    Tokenize.Tokens.startpos(t)[1] >= line && return join(stack, ".")

    if Tokenize.Tokens.kind(t) == Tokenize.Tokens.LSQUARE
      unfinished_bracket = true
      continue
    end

    if unfinished_bracket
      if Tokenize.Tokens.kind(t) == Tokenize.Tokens.RSQUARE
        unfinished_bracket = false
      end
      continue
    end

    if Tokenize.Tokens.exactkind(t) in SCOPE_STARTERS
      if Tokenize.Tokens.exactkind(t) == Tokenize.Tokens.MODULE ||
         Tokenize.Tokens.exactkind(t) == Tokenize.Tokens.BAREMODULE

        pos = Tokenize.Lexers.position(ts)
        # not sure what happens when changing the iterator state while iterating,
        # but in theory nothing bad should happen, right?
        t, e = Tokenize.Tokens.next(ts, false)
        t, _ = Tokenize.Tokens.next(ts, e)
        m = Tokenize.Tokens.untokenize(t)
        push!(stack, m)
      else
        n_openers += 1
      end
    elseif Tokenize.Tokens.exactkind(t) == Tokenize.Tokens.END
      if n_openers == 0
        !isempty(stack) && pop!(stack)
      else
        n_openers -= 1
      end
    end
  end
end

codemodule(code, pos::Cursor) = codemodule(code, pos.line)

"""
Takes a given Julia source file and another (absolute) path, gives the
line on which the path is included in the file or 0.
"""
function includeline(file::AbstractString, included_file::AbstractString)
  i = 0
  open(file) do io
    for (index, line) in enumerate(eachline(io))
      m = match(r"include\(\"([a-zA-Z_\.\\/]*)\"\)", line)
      if m != nothing && normpath(joinpath(dirname(file), m.captures[1])) == included_file
        i = index
        break
      end
    end
  end
  return i
end

"""
Takes an absolute path to a file and returns the (file, line) where that
file is included or nothing.
"""
function find_include(path::AbstractString)
  for file in @> path dirname dirsnearby jl_files
    line = includeline(file, path)
    line > 0 && (return file, line)
  end
end

"""
Takes an absolute path to a file and returns a string
representing the module it belongs to.
"""
function filemodule_(path::AbstractString)
  loc = find_include(path)
  if loc != nothing
    file, line = loc
    mod = codemodule(readstring(file), line)
    super = filemodule(file)
    if super != "" && mod != ""
      return "$super.$mod"
    else
      return super == "" ? mod : super
    end
  end
  return ""
end

const filemodule = memoize(filemodule_)

# Get all modules

children(m::Module) =
  @>> names(m, true) map(x->getthing(m, [x])) filter(x->isa(x, Module) && x ≠ m)

function allchildren(m::Module, cs = Set{Module}())
  for c in children(m)
    c in cs || (push!(cs, c); allchildren(c, cs))
  end
  return cs
end
