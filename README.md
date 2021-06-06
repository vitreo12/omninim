# omninim v.1.4.8

Patched version of the Nim compiler in order to be embedded within the Omni audio DSL.

## NOTES:

All additional code is prepended with the `#OMNI` comment.

## Additions:

1) On failed compilation, it does not `quit`, but it uses `setjmp` and `longjmp` to implement a low-level
`try` / `catch` mechanism. Check the `compiler/omni/omni_nim_compiler.nim` folder for the implementation of the `omniNimCompile` function.

2) Disable `stdin` handling. All `conf` settings need to be manually assigned via code. 

## License

Please read the [copying.txt](copying.txt) file for more details.

Copyright © 2006-2020 Andreas Rumpf, all rights reserved.
