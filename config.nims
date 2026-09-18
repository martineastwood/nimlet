import std/os

# Prefer sibling checkouts when developing in the niminal workspace.
# Brew and lone-tarball builds skip these and use nimble.paths instead.
for p in ["../nimgent/src", "../nimwire/src", "../nimterm/src", "../../nimwire/src"]:
  let abs = thisDir() / p
  if dirExists(abs):
    switch("path", abs)

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
