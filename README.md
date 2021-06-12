# omninim v.0.5.0 - Nim v.1.4.8

Patched version of the Nim compiler in order to be embedded within the Omni audio DSL.

## Notes:

All additional code is prepended with the `#OMNI` comment.

## Additions:

1) On failed compilation, it does not `quit`, but it uses `setjmp` and `longjmp` to implement a low-level
`try` / `catch` mechanism. Check the `compiler/omni/omni_nim_compiler.nim` folder for the implementation of the `omniNimCompile` function.

2) Disabled `stdin` handling. All `conf` settings need to be manually assigned via code. 

3) Disabled `stdout` and `stderr` handling. The output of compilation is assigned to the
`conf.compilationOutput` variable.

4) Disabled the need for `-d:selftest`, which would run the compiler cmd line interface in
`compiler/nim.nim`.

## License

### Nim

Please read the [copying.txt](copying.txt) file for more details.

Copyright © 2006-2020 Andreas Rumpf, all rights reserved.

### Omni

MIT License

Copyright (c) 2020-2021 Francesco Cameli

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
