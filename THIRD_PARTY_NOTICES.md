# Third-party notices

Koi's own code is licensed under GPL-3.0-only. The third-party materials below
retain their own licenses. License links use the same relative paths in the
repository and in the app's Resources directory.

These notices cover the default libghostty-vt Mac XCFramework and the Mac and
Linux core builds, not all dependencies of the Ghostty application. The pinned
VT build enables Kitty graphics and SIMD; it uses uucode and Wuffs and links
bundled SIMDUTF and Highway. The Linux core target is x86_64-linux-musl. Build
options or toolchain changes can change the dependencies and require another
review.

## Updates

- **Sparkle** 2.10.1 — Copyright (c) 2006-2017 Andy Matuschak, Elgato Systems
  GmbH, Kornel Lesiński, Mayur Pawashe, C.W. Betts, Petroules Corporation, Big
  Nerd Ranch and others; [MIT license](licenses/sparkle.txt), which also carries
  the notices of the components Sparkle bundles (such as its Ed25519,
  bsdiff and sais code). The app embeds `Sparkle.framework` without its
  sandbox-only XPC services. Source:
  [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/tree/2.10.1).

## Ghostty and terminal data

- **libghostty-vt** — Copyright (c) 2024 Mitchell Hashimoto, Ghostty
  contributors; [MIT license](licenses/ghostty.txt). Source:
  [Ghostty LICENSE at 0fe113a35370667d8c4d6970ee5c1704825dce6b](https://github.com/ghostty-org/ghostty/blob/0fe113a35370667d8c4d6970ee5c1704825dce6b/LICENSE).
- **uucode** — Copyright (c) 2026 Jacob Sandlund;
  [MIT license](licenses/uucode.txt). Its Unicode tables and UTF-8 decoder
  also carry the [Unicode license](licenses/uucode-unicode.txt) and
  [Bjoern Hoehrmann's notice](licenses/uucode-bjoern-hoehrmann.txt).
  The Unicode data files in this version also identify Copyright © 2026
  Unicode, Inc. Sources at revision `ea62149739404a73c202b48a33bf6dd2af4bd9b0`:
  [uucode license](https://github.com/jacobsandlund/uucode/blob/ea62149739404a73c202b48a33bf6dd2af4bd9b0/LICENSE.md),
  [Unicode notice](https://github.com/jacobsandlund/uucode/blob/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_unicode), and
  [decoder notice](https://github.com/jacobsandlund/uucode/blob/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_Bjoern_Hoehrmann).
  Ghostty's own UTF-8 decoder also credits Hoehrmann.
- **Wuffs** — Copyright 2017 and 2023 The Wuffs Authors. The generated C
  library offers Apache-2.0 or MIT; this distribution uses the
  [MIT alternative](licenses/wuffs-mit.txt). Sources at revision
  `7411f488fe2e2c205c3d3b3d28638b7356522930`:
  [license](https://github.com/google/wuffs/blob/7411f488fe2e2c205c3d3b3d28638b7356522930/LICENSE-MIT) and
  [generated C](https://github.com/google/wuffs/blob/7411f488fe2e2c205c3d3b3d28638b7356522930/release/c/wuffs-v0.4.c).
- **SIMDUTF** — Copyright 2021 The simdutf authors; this distribution uses
  the [MIT alternative](licenses/simdutf-mit.txt). Its bundled CPU detection
  includes a [separate BSD notice](licenses/simdutf-pytorch.txt), and its
  UTF-8 validation credits code from Google Fuchsia under the
  [Apache 2.0 license](licenses/highway-apache.txt). The vendored header
  identifies SIMDUTF 9.0.0 (the Ghostty wrapper's package version is distinct).
  Sources: [SIMDUTF 9.0.0 MIT license](https://github.com/simdutf/simdutf/blob/v9.0.0/LICENSE-MIT) and
  [Ghostty's vendored header at its pinned revision](https://github.com/ghostty-org/ghostty/blob/0fe113a35370667d8c4d6970ee5c1704825dce6b/pkg/simdutf/vendor/simdutf.h).
- **Highway** — Copyright Google LLC, Arm Limited and/or its affiliates, and
  The Highway Project Authors. The built sources include Apache-2.0 and
  BSD-3-Clause notices; see the [Apache license](licenses/highway-apache.txt)
  and [BSD license](licenses/highway-bsd.txt). Ghostty modifies Highway's
  runtime dispatch files. Sources at revision
  `66486a10623fa0d72fe91260f96c892e41aceb06`:
  [Apache license](https://github.com/google/highway/blob/66486a10623fa0d72fe91260f96c892e41aceb06/LICENSE),
  [BSD license](https://github.com/google/highway/blob/66486a10623fa0d72fe91260f96c892e41aceb06/LICENSE-BSD3),
  and [Ghostty's modified files](https://github.com/ghostty-org/ghostty/tree/0fe113a35370667d8c4d6970ee5c1704825dce6b/pkg/highway/src/cpp).
- **X.Org RGB color data** — Ghostty embeds `rgb.txt`; see the
  [X.Org notices](licenses/xorg-rgb.txt). The embedded file matches the
  `rgb.txt` in [X.Org rgb 1.1.1](https://xorg.freedesktop.org/archive/individual/app/rgb-1.1.1.tar.gz)
  byte for byte; its `COPYING` is reproduced here.

## Zig and Linux libc

The builds use Zig's standard library and may include compiler runtime code:
Copyright (c) Zig contributors, [MIT license](licenses/zig.txt). The Linux
core statically links musl: Copyright © 2005–2020 Rich Felker, et al.; see
its full [copyright and license file](licenses/musl.txt), including its
third-party attribution. The [TRE notice](licenses/musl-tre.txt) is included
for musl's separately licensed regular-expression code.

The Linux build also requests C++ runtime support. Zig supplies LLVM's C++
headers and runtimes under Apache-2.0 with LLVM exceptions and the additional
notices reproduced in their full license files:
[libc++](licenses/llvm-libcxx.txt), [libc++abi](licenses/llvm-libcxxabi.txt),
and [libunwind](licenses/llvm-libunwind.txt). These were copied verbatim from
Zig 0.17.0's `lib/zig/libcxx/LICENSE.TXT`, `libcxxabi/LICENSE.TXT`, and
`libunwind/LICENSE.TXT`. System-provided macOS C++ libraries are not copied
into the app bundle.

These texts were copied from the installed Zig 0.17.0 toolchain: `LICENSE`,
`lib/zig/libc/musl/COPYRIGHT`, and the notice in
`lib/zig/libc/musl/src/regex/regcomp.c`, respectively. Its package records [Zig 0.17.0 source](https://ziglang.org/download/0.17.0/zig-0.17.0.tar.xz);
the repository specifies a minimum Zig version rather than pinning a toolchain,
so a distribution built with another version must review its bundled runtime
and libc notices.

## Program logos

Program logos from Simple Icons are provided under
[CC0 1.0](licenses/cc0-1.0.txt). This is the complete license text supplied
with the program-logo assets (`src/app/resources/programs/logos/LICENSE.md`
in the source tree). Brand names and logos identify the programs running in a
pane.

The OpenCode, Cursor, Qwen and Cline logos are copied without modification from Simple Icons revision
`3237c86aca8e54fdf55b6a33de8b64014b1ff47a`, under the same CC0 license. Its
source revisions and checksums are recorded in the program-logo manifest.
