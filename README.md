# omninim v.1.4.8

Patched version of the Nim compiler in order to be embedded within the Omni audio DSL.

## NOTES:

All additional code is prepended with the `#OMNI` comment.

## Additions:

1) On failed compilation, do not `quit`, but use `setjmp` and `longjmp` to implement a low-level
`try` / `catch` mechanism.

2) Disable `stdin` handling and assign all `conf` options via code.

3) Simplified `handleCmdLine` function, called `omniNimCompile`.

## License

Please read the [copying.txt](copying.txt) file for more details.

Copyright © 2006-2020 Andreas Rumpf, all rights reserved.
