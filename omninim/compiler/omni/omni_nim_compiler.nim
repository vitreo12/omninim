# Nim's copyright:
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

# Omni's copyright:
#
# MIT License
# 
# Copyright (c) 2020-2021 Francesco Cameli
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This file contains simplified versions of Nim's compile function. The entry point for compilation
# is omniNimCompile.

import
  ../commands, ../options, 
  #[ os, ]# ../main, 
  ../idents, ../cmdlinehelper,
  #[ ../pathutils, ]# ../modulegraphs

import omni_setjmp

#Like processCmdLine in nim.nim, without actually parsing
proc processCmdLine(pass: TCmdLinePass, cmd: string; config: ConfigRef) = discard

#This would set correct projectPath, which omni already handles... After testing, this could
#probably just be removed altogether
proc processProjectPath*(self: NimProg, conf: ConfigRef) = discard
  # if conf.projectName != "":
  #   try:
  #     conf.projectFull = canonicalizePath(conf, AbsoluteFile conf.projectName)
  #   except OSError:
  #     conf.projectFull = AbsoluteFile conf.projectName
  #   let p = splitFile(conf.projectFull)
  #   let dir = if p.dir.isEmpty: AbsoluteDir getCurrentDir() else: p.dir
  #   conf.projectPath = AbsoluteDir canonicalizePath(conf, AbsoluteFile dir)
  #   conf.projectName = p.name
  # else:
  #   conf.projectPath = AbsoluteDir canonicalizePath(conf, AbsoluteFile getCurrentDir())

#Simplified handleCmdLine without stdin support and commandLine checks.
#returns false for succes, true for failure.
proc omniNimCompile*(conf: ConfigRef) : bool =
  let cache = newIdentCache()

  # write to conf.compilationOutput and not to stdout or stderr
  incl(conf.globalOptions, {optCompilationOutput}) 
  excl(conf.globalOptions, {optUseColors}) #--colors:off

  let self = NimProg(
    supportsStdinFile: false, #it is true here for normal nim
    processCmdLine: processCmdLine
  )
  self.initDefinesProg(conf, "nim_compiler")
  self.processProjectPath(conf)
  var graph = newModuleGraph(cache, conf)

  # This was causing segfaults... It is useless anyway as omni does not use nim.cfg / config.nims
  # if not self.loadConfigsAndRunMainCommand(cache, conf, graph): return true

  var failure : bool

  #try
  if not bool(omni_setjmp(conf.omniJmpBuf)):
    mainCommand(graph)
    failure = false
  #catch
  else:
    failure = true

  return failure
