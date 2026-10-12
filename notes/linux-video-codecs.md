# H.264 / H.265 on Linux: who can decode them on the GPU (2026-09-30)

Why an H.264 wallpaper decodes on the CPU on some Linux systems, what other free software
does about it, and what that means for how zmural is shipped. Each claim is tagged:
**[MEASURED]** run in the dev container (Fedora 44, Radeon iGPU + RX 9070 XT, Mesa 26.2),
**[SOURCE]** read from the linked page, **[DERIVED]** my inference from the two.

## The mechanism

GPU decoding of a video needs two separate pieces, and both must include the codec:

1. **FFmpeg's decoder for the codec.** The VA-API and Vulkan "hwaccels" hang off FFmpeg's own
   native H.264/HEVC decoders; without those there is nothing to accelerate. [SOURCE: the
   Bluefin PR below says so in as many words]
2. **The GPU driver's video support.** For AMD (and nouveau) that is Mesa, which since 22.2 has
   a build option, `video-codecs`, so a distribution can leave out `h264dec`, `h265dec`,
   `vc1dec` and the encoders. It applies to VA-API, VDPAU and Vulkan Video alike. [SOURCE:
   Phoronix, "Mesa can now be built with select video codecs disabled"]

The reason is patents, not code quality: H.264 and H.265 are covered by patent pools, and a
distributor who ships an implementation can be asked for licence fees. [SOURCE: LWN 910978]

AV1 and VP9 are royalty-free and are left in everywhere. [MEASURED: stock Fedora Mesa lists
VP9 and AV1 decode on both GPUs, and nothing else but JPEG]

## Which systems are affected

| System | Mesa has H.264/H.265 | FFmpeg has them | H.264 on the GPU out of the box |
|---|---|---|---|
| Fedora (and RHEL-likes) | no, since F37 (2022) | no: `libavcodec-free` has only Cisco's OpenH264, a software decoder | **no** |
| openSUSE | no (same decision) | no | **no**; Packman repo restores it |
| Bazzite, Bluefin (Fedora-based images) | yes | yes (they patch it back in) | yes |
| Debian, Ubuntu | yes (Debian re-enabled them explicitly) | yes | yes |
| Arch and derivatives | yes (Mesa's default is all codecs) | yes | yes |
| Any distro, **Flatpak app from Flathub** | yes, the runtime's own Mesa | yes, the runtime's `codecs-extra` | yes (see below) |
| Intel GPUs on Fedora | n/a: Intel's own VA-API driver, not Mesa | still needs the FFmpeg half | partly |
| NVIDIA proprietary | n/a: the driver has them | still needs the FFmpeg half | partly |

Sources: Phoronix and LWN on Fedora and openSUSE; the Arch commit "Don't specify video-codecs
manually"; the Phoronix forum thread on Debian; Universal Blue's codec page and the Bluefin PR.
So this is a **Fedora and openSUSE problem, and on those an AMD problem first**. [DERIVED]

On Fedora the fix is two RPM Fusion packages, and **both** are needed:
`mesa-va-drivers-freeworld` and `libavcodec-freeworld`. [SOURCE: Fedora wiki, Hardware Video
Acceleration] [MEASURED: 1440p60 H.264 in `zmural-video`: 13.2% of a core with neither,
13.3% with the Mesa one alone, 1.4% with both]

## What other free software does

Nobody refuses H.264. There are three approaches:

- **Use whatever the system has, fall back to the CPU.** mpv, Celluloid, waywallen, GStreamer
  apps, Firefox's distro builds. On Fedora these all land on software decoding until the user
  adds RPM Fusion. Fedora's Chromium build has no H.264 at all without RPM Fusion's
  `chromium-libs-media-freeworld`. [SOURCE: Fedora discussion threads, Fedora wiki]
- **Bundle your own FFmpeg.** VLC carries its own codec libraries, which is why "only VLC can
  play this" threads exist on Fedora. That gets software H.264 everywhere, but it cannot get
  GPU decoding where the system's Mesa lacks the codec: the driver half is still missing.
  [SOURCE: Fedora discussion 184943; DERIVED for the GPU half]
- **Ship as a Flatpak on Flathub and let the runtime bring both halves.** This is the only
  route that fixes GPU decoding on Fedora without asking the user for anything.

### The Flatpak route, checked

The freedesktop runtime (`org.freedesktop.Platform`) used to offer `ffmpeg-full` and an
OpenH264 extension. From 25.08 those are replaced by one `codecs-extra` extension, and Mesa
comes in two builds: `GL.default//25.08` without the patented codecs and
`GL.default//25.08-extra` with them. A user or distributor who wants none of it can `flatpak
mask` the `-extra` branches. [SOURCE: Freedesktop SDK 25.08 release notes; bbhtt, "Closing the
chapter on OpenH264"]

Checked here: [MEASURED]
- Installing `org.freedesktop.Platform//25.08` from Flathub pulled in `GL.default//25.08`,
  `GL.default//25.08-extra` and `codecs-extra//25.08-extra` by itself, with no extra step
  (259 MB download, 669 MB installed, 77 s).
- Pointing `vainfo` at each Mesa build on the Radeon iGPU: the plain one lists VP9 and AV1
  only; the `-extra` one also lists H.264 (Baseline, Main, High) and HEVC (Main, Main10),
  decode and encode.
- `codecs-extra`'s `libavcodec.so.61` contains `h264_vaapi`, `hevc_vaapi` and `h264_vulkan`.
- **Not checked:** an actual decode inside the sandbox. `flatpak run` doesn't work in this
  container (bwrap can't remount), so the last step is inferred from the parts. It also says
  nothing about Fedora's own Flatpak remote, whose runtime does not carry these extensions.
  [SOURCE: Yaakov Selkowitz, "How to use OpenH264 with Fedora Flatpaks"]

libmpv is not in the runtime; a zmural Flatpak would build mpv against the runtime's FFmpeg,
as the mpv and Celluloid Flatpaks do. [DERIVED]

## What this means for zmural

1. **Don't bundle codecs in a plain Linux build.** A bundled FFmpeg can't supply the driver
   half, so it would not move H.264 onto the GPU on the very systems that lack it, and it would
   make us the distributor of the patented decoder. [DERIVED]
2. **Owner's decision (2026-09-30): detect, fall back, tell once.** zmural installs nothing.
   It uses the system's libmpv, decodes on the GPU when the system can and on the CPU when it
   can't, logs which, and the first time a format lands on the CPU shows one notification
   ("No GPU decoder for H.264 found"), never repeated for that format. The README names the
   two Fedora packages for those who want them.
3. **The Flatpak is the real answer for Fedora and openSUSE users**, and it is already the
   planned Linux channel (MILESTONES M8). Two known limits: layer-shell doesn't work from
   inside a Flatpak (waywallen found the same), so it serves KDE and GNOME, which is what the
   owner runs; and the plugin/extension still has to be installed into the host desktop.
4. **Distro packages** (a Fedora COPR RPM) can only ever be as capable as the distro's own
   Mesa and FFmpeg, so on Fedora they need the RPM Fusion hint.
5. Wallpapers encoded as AV1 or VP9 avoid the whole question, and are smaller: at equal VMAF
   on one 1080p test clip, VP9 was 69 to 84% and AV1 54 to 71% of the H.264 size. [MEASURED]

## Sources

- https://lwn.net/Articles/910978/ (The disabling of hardware codecs in community distributions)
- https://www.phoronix.com/news/Fedora-Disable-Bad-VA-API
- https://www.phoronix.com/news/Mesa-Optional-Video-Codecs
- https://linuxiac.com/fedora-and-opensuse-are-dropping-support-for-some-video-codecs/
- https://fedoraproject.org/wiki/Hardware_Video_Acceleration
- https://fedoraproject.org/wiki/OpenH264
- https://discussion.fedoraproject.org/t/h-264-support-in-fedora-workstation-by-default/114521
- https://discussion.fedoraproject.org/t/only-vlc-flatpak-can-play-mp4s-with-certain-h-264-video-codec/184943
- https://www.mail-archive.com/arch-commits@archlinux.org/msg904211.html (Arch: "Don't specify video-codecs manually")
- https://universal-blue.discourse.group/t/codecs-and-multimedia-support/314
- https://github.com/projectbluefin/dakota/pull/1687
- https://discourse.flathub.org/t/freedesktop-sdk-25-08-0-released/10399
- https://bbhtt.in/posts/closing-the-chapter-on-openh264/
- https://yselkowitz.github.io/blog/2025/08/12/openh264-fedora-flatpaks.html
