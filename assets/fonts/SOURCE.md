# Fonts

The pixel theme sets its captions in three TrueType files of the Liberation
Fonts, version 2.1.5:

- `LiberationSans-Regular.ttf`, the interface face at 13 px;
- `LiberationSans-Bold.ttf`, the title bars and the farewell screen;
- `LiberationMono-Regular.ttf`, the fixed-pitch face of Notepad and the editor.

## Where they come from

The Liberation Fonts project, https://github.com/liberationfonts/liberation-fonts,
release 2.1.5. The files are copied unmodified from the Debian package
`fonts-liberation` 1:2.1.5-3 (`/usr/share/fonts/truetype/liberation/`). SHA-256:

```
4659bc0c58c5028dd488ec928d41d9265db43d9b669fc14ca8b0832daca7b144  LiberationSans-Regular.ttf
3973aa5054fb467dd5627245d3dc82e37bf16fe075756156a570455871351582  LiberationSans-Bold.ttf
395fa5ab8d40c8eba390ced528744ea75a7f69aabf3e68b6f925ca0e39a27370  LiberationMono-Regular.ttf
```

## Licence

The SIL Open Font License, Version 1.1. The full text, with the copyright
notices, is in [LICENSE](LICENSE):

- digitized data copyright (c) 2010 Google Corporation, with Reserved Font
  Arimo, Tinos and Cousine;
- copyright (c) 2012 Red Hat, Inc., with Reserved Font Name Liberation.

The OFL permits bundling the fonts with software, this module included, as
long as every copy carries the copyright notices and the licence. That is why
LICENSE lies next to the files and has to travel with them. The fonts may not
be sold by themselves, and a modified version may not use the name Liberation.
They stay under the OFL: the module's MIT licence does not cover them.

## How the shell uses them

The directory is the registry entry `chicago.shell.theme:fonts`, an
`fs.directory` with `base: module`, named under `embed:` in `wippy.yaml` so a
packed module carries it too. The shell reads the files as bytes through
`chicago.shell.theme:font_set`. `CHICAGO_FONTS` names another store instead.
Before the fonts shipped with the module, pixel mode depended on the
machine's `fonts-liberation` package.
