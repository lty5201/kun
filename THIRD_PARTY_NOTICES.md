# Third-party notices

kun is licensed LGPL-3.0-only. The notices below cover code ported into kun
from other LGPL-3.0-only projects and the protocols it implements. Ported files
carry a `Ported from …` comment naming their origin; the project license does
not replace any file-level obligation.

## Kumone

- Upstream: https://github.com/missuo/kumone
- License: LGPL-3.0-only
- kun is a fork of Kumone and retains its SwiftUI player, lyrics, settings
  and core playback code.

## Moumusic

- Upstream: https://github.com/jiajia2222/Moumusic
- License: LGPL-3.0-only
- The LX (Luoxue) third-party source engine, the `AudioQuality` /
  `PlaybackSourceMode` settings model, the NetEase daily check-in and the
  related player / download / settings UI were ported 1:1 (or with minimal
  adaptation noted in each file's header) from Moumusic's iOS code
  (`platforms/ios/Sources/Kumone/`).

## LX Music Mobile

- Upstream: https://github.com/lyswhut/lx-music-mobile
- License: Apache-2.0
- The LX User API protocol (source scripts, `lx.on('request')` handlers,
  quality tokens such as `128k` / `320k` / `flac` / `flac24bit` / `master`)
  implemented by the ported LX engine originates from LX Music Mobile.

kun does not bundle or distribute third-party source scripts or provider URLs.
Sources are user configuration: users import their own LX source scripts and
are responsible for them, and must follow applicable service terms, copyright
rules and upstream licenses.
