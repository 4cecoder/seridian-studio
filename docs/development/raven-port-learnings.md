# Raven C -> Zig port: learnings that shape the workflows

Each item is a fact found by running the oracle (`vendor/raven/zig/check.sh`) on Linux, Zig 0.18.0-dev.738.
The workflows must encode these, so no agent rediscovers them.

1. **Linux baseline.** `zig/baseline/` shipped with Darwin files only. On Linux `test_render` is skipped and the
   check reports a regression. Record with `./check.sh --make-baseline` on the target OS first.
2. **Stack probes.** A Zig object built with `build-obj` calls `__zig_probe_stack` for large frames. Without the
   compiler runtime in the object, every link of `libraven.a` fails. `-fcompiler-rt` supplies it but adds ~470
   exported symbols (fails the symbol check) and pulls in libm needs. The object is built with `-fno-stack-check`
   (cmake/RavenZig.cmake): no extra symbols, no probes.
3. **libm, pthread, dl, X11 on Linux.** Zig objects call `pow`, `powf`, `fmod`, `fmodf`, `sinf`. The check's own
   link lines must add `-lX11 -lm -lpthread -ldl` on Linux (check.sh, step 4). CMake already links them.
4. **Variadic functions (va_list ABI).** On x86-64 System V a C `va_list` is an array of one struct, so it decays to a
   pointer when passed to C. Declaring `vsnprintf` with `std.builtin.VaList` by value copies the 24-byte struct and
   vsnprintf reads garbage (format=0xffffffff, SIGSEGV in vsnprintf). The va_list must be passed by pointer (`&args`)
   on non-Windows targets. Fix once in src/sys/libc.zig and at every caller (xml_components, error, memory, xml_loader).
   Any translation with a variadic parameter needs a test that formats through it and checks the output.
5. **Oracle ordering.** `check.sh` checks build, symbols, layout, fonts, then ctest. A ctest SEGFAULT is a real
   regression of an earlier translation, not an environment problem, and must be fixed before new files are added.
6. **Stop on the first failure.** Each file is verified alone (`check_unit.sh`) before the library check; a file
   that breaks the library check is reverted from ported.txt, not patched around.
7. **The oracle only tests what is in `ported.txt`.** A workflow that runs the oracle without adding the accepted
   files tests nothing new and reports PASS anyway (wave 2 did this: "18 ported files" while 21 were accepted). The
   integrator must add each accepted file to `ported.txt` first, then run `check.sh`, and report the count of
   ported files in the result. "Accepted" from `check_unit.sh` alone is not integration.
