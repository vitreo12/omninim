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

#With zig c these should work anywhere (including Windows)
proc dup(oldfd: FileHandle): FileHandle {.importc, header: "unistd.h".}
proc dup2(oldfd: FileHandle, newfd: FileHandle): cint {.importc, header: "unistd.h".}

template captureStdout*(compilationOutput : untyped, body: untyped) =
  # tmp file. Use addr of something to generate a random number
  let tmpFileName = getTempDir() & "/omni_nim_compiler" & $(cast[culong](stdout.unsafeAddr)) & ".txt"
  # Get handle to stdout
  var stdout_fileno = stdout.getFileHandle()
  # Duplicate stoud_fileno
  var stdout_dupfd = dup(stdout_fileno)
  # Create a new file
  var tmp_file: File = open(tmpFileName, fmWrite)
  # Get the FileHandle (the file descriptor) of your file
  var tmp_file_fd: FileHandle = tmp_file.getFileHandle()
  # dup2 tmp_file_fd to stdout_fileno -> writing to stdout_fileno now writes to tmp_file
  discard dup2(tmp_file_fd, stdout_fileno)
  # Actual code
  body
  # Force flush
  tmp_file.flushFile()
  # Close tmp
  tmp_file.close()
  # Read tmp
  compilationOutput = readFile(tmpFileName)
  # Restore stdout
  discard dup2(stdout_dupfd, stdout_fileno)
