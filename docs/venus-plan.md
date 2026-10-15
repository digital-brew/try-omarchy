# Venus plan: Vulkan pass-through on the Mac

Status: research and plan, 2026-10-15. Nothing below has run in our VM yet.
Upstream state was checked against the QEMU, virglrenderer, Mesa, MoltenVK and
UTM repositories on this date. The source and patch reads used QEMU at the
pinned commit `c3d48b7d1e89604920e5b81b91140c2ad39a1943` (11.1.1) and the
pinned `startergo/homebrew-virglrenderer` v1.0.42 tap.

## Summary

Venus lets guest Vulkan calls be serialized over virtio-gpu and replayed by
virglrenderer on a host Vulkan driver, which on a Mac is MoltenVK or Mesa's
KosmicKrisp, both running on Metal.

**Verdict: feasible as an opt-in experiment for Vulkan applications. It will
not speed up the desktop.** Note these points:

- **It needs our own patches to both QEMU and virglrenderer.** As of this date
  neither upstream QEMU nor any virglrenderer release runs Venus on macOS.
- **Hyprland has no Vulkan renderer, so the compositor stays on VirGL.**
  Hyprland 0.56 renders only with OpenGL ES.
- **Moving the compositor to Zink on Venus is blocked.** Blob scanout requires
  a Linux dma-buf in QEMU. Also, UTM, which ships Venus on macOS, reports that
  desktop rendering on Vulkan does not work because geometry-shader support is
  missing.
- **Vulkan application windows cannot yet be composited by our display.** A
  Vulkan window reaches Hyprland as a Venus blob. With our native-OpenGL
  display (`cocoa,gl=on`), virglrenderer has no way to import such a blob into
  the compositor's GL context. The existing import code needs EGL (ANGLE,
  `gl=es`), which this repo left for browser-compatibility reasons (see
  [performance](performance.md)).

The realistic gains are:

- Vulkan compute, for example llama.cpp. Reported numbers are about 50–57% of
  native Metal.
- Headless or offscreen Vulkan rendering.
- Later, Vulkan applications in windows, once an import path exists for
  `gl=on`.

Hyprland at 5K and browser compositing will not get faster from Venus. For
those, the work in [performance](performance.md) on the VirGL path remains the
lever.

The spike is worth doing because most of the required pieces now exist
upstream or in UTM:

- virglrenderer main has macOS Venus support.
- Linux 7.2 and the guest's Mesa 26.2.4 already honor 16 KiB blob alignment.
- UTM 5.0 ships the whole stack.

## Current path

```
Hyprland / Chromium / apps (GL, GLES)
  |
Mesa virgl (OpenGL 4.1, GLES 3.0)          guest, Mesa 26.2.4, kernel 7.2.8
  |
virtio-gpu-gl-pci  (no blob, no hostmem)    -- VM boundary --
  |
virglrenderer 1.3.0 + startergo tap + virgl-native-opengl.patch
  |  vrend, Apple OpenGL 4.1 core (CGL)
QEMU 11.1.1 Cocoa display, gl=on           host
```

The guest kernel reports
`[drm] features: +virgl +edid -resource_blob -host_visible` and
`+context_init -blob_alignment`, with two capsets (VIRGL, VIRGL2):

- `-resource_blob -host_visible` means only that we start the device without
  `blob=true,hostmem=`.
- `-blob_alignment` shows that the guest kernel knows
  `VIRTIO_GPU_F_BLOB_ALIGNMENT` but QEMU does not offer it.

Guest pages are 4 KiB (`CONFIG_ARM64_4K_PAGES=y`), host pages are 16 KiB.

The runtime is already partly Venus-capable, by accident.
`macos/build-qemu-gpu-runtime.sh` configures virglrenderer with `-Dvenus=true`
and applies the tap's `virglrenderer-macos-unified.patch`. That patch carries an
older form of osy's (UTM) macOS Venus port: MTLHeap export, emulated
`VK_KHR_external_memory_fd`, `VK_EXT_image_drm_format_modifier` and dma-buf, and
an in-process render-server thread. Nothing uses it, for three reasons:

- **The render server runs out of process, so blob mapping fails.** Venus is
  built with the default `render-server-worker=process`, and QEMU passes
  `VIRGL_RENDERER_RENDER_SERVER`. Blobs are exported as raw `MTLHeap` pointers,
  which the patch refuses to send across a process boundary ("not in_process,
  cannot send pointers").
- **The render server is not shipped.** `virgl_render_server` is not in
  `macos/runtime-files.txt`, and its compiled-in path points into the deleted
  scratch prefix.
- **No Vulkan driver or loader is bundled.**

## Target path

```
Vulkan app / vkcube / llama.cpp           Hyprland, Chromium (unchanged)
  |  Vulkan                                 |  GL, GLES
Mesa venus (vulkan-virtio)                Mesa virgl
  |  Venus capset (4)                       |  VIRGL2 capset
  +---------------- virtio-gpu-gl-pci,blob=true,hostmem=4G,venus=true ----+
  |                       (one device, both context types)              |
  |  blob resources -> hostmem BAR (16 KiB aligned) -> hv_vm_map        |
  v                                                                      v
virgl_render_server (process, posix_spawn)       libvirglrenderer: vrend on CGL
  |  vkr: shm + VK_EXT_external_memory_host/metal                        |
MoltenVK (Metal)                                  Apple OpenGL           |
                                                                         v
                                          QEMU Cocoa display, gl=on, scanout
                                          stays a VirGL 3D resource
```

Scanout remains a VirGL resource that Hyprland composites in GL. Venus contexts
coexist with VirGL contexts on one device. QEMU always registers VIRGL and
VIRGL2 and adds VENUS when `venus=true` (`hw/display/virtio-gpu-virgl.c`).

## What upstream supports

### QEMU

- **Venus support:** Venus contexts arrived in QEMU 9.2 (2024-12). Our pin,
  11.1.1, has `venus` on `virtio-gpu-gl`, which requires `blob=true` and
  `hostmem=`
  ([docs](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)).
- **No udmabuf or memfd needed:** the udmabuf requirement for blobs is skipped
  when VirGL is enabled (`virtio_gpu_device_realize`). The
  `memory-backend-memfd` in Mesa's example command is a Linux convenience, not a
  requirement.
- **Render server flag:** with `venus=true`, QEMU initializes virglrenderer
  with `VIRGL_RENDERER_VENUS | VIRGL_RENDERER_RENDER_SERVER`, which selects an
  out-of-process render server.
- **Blob mapping:** QEMU 11.1 maps a blob with
  `virgl_renderer_resource_map_fixed()`, which does an `mmap(MAP_FIXED)` over
  the hostmem window. This is enabled whenever virglrenderer is 1.3.0 or newer
  (`VIRGL_HAS_MAP_FIXED`). Otherwise QEMU falls back to a `ram_ptr` subregion
  that HVF maps with `hv_vm_map`.
- **No blob alignment offered:** QEMU 11.1 does not offer
  `VIRTIO_GPU_F_BLOB_ALIGNMENT`.
- **No blob scanout on macOS:** `virgl_cmd_set_scanout_blob` requires a dma-buf
  fd ("resource not backed by dmabuf").
- **macOS series are still unmerged as of this date:**
  - **UTM (osy):** RFC "[virtio-gpu-virgl: introduce Venus support for
    macOS](https://patchew.org/QEMU/20251203040754.94487-1-j@getutm.app/)"
    (2025-12, v2 exists). It covers blob page-alignment checks, Metal texture
    scanout and native blob scanout, and builds on Akihiko Odaki's GLES Cocoa
    work. Fork: <https://github.com/utmapp/qemu/tree/submit/macos-venus>.
  - **Lucas Amaral, "virtio-gpu: enable Venus/Vulkan without OpenGL display"**
    v5 ([thread](https://ratatoskr.run/qemu-devel/2026/03/14435425/t)). It
    advertises `VIRTIO_GPU_F_BLOB_ALIGNMENT` equal to the host page size.
    Review in May 2026 asked for a v6.
  - **Lucas Amaral, "hvf: map granule abstraction"** v4
    ([thread](https://ratatoskr.run/qemu-devel/2026/03/14435417/t)). It
    validates host-page alignment before `MAP_FIXED` and falls back to a
    subregion otherwise. It also adds `ipa-granule=auto|4k|16k` using
    `hv_vm_config_set_ipa_granule()` on macOS 26.

### virglrenderer

- **Releases:** the latest release is 1.3.0 (2026-02-10), our pin. All macOS
  Venus work is on main only.
- **Merged to main after 1.3.0:**
  - !1600 macOS build: kqueue, stream-socket framing.
  - !1601 `posix_spawn` worker, because Metal's XPC state breaks a bare
    `fork()`.
  - !1607 process-model preparation.
  - [!1602](https://gitlab.freedesktop.org/virgl/virglrenderer/-/merge_requests/1602)
    "Metal shared memory for macOS Venus" (2026-04-24). It allocates
    page-aligned POSIX shm, wraps it with `newBufferWithBytesNoCopy`, imports it
    with `VK_EXT_external_memory_metal`, and exports it to the VMM as
    `VIRGL_RESOURCE_FD_SHM`. It reports vkmark at about 1770 FPS in an aarch64
    guest on an M4 Max.
  - !1621 MoltenVK through the Vulkan loader.
  - !1634 and !1635 fixes.
  - Main head on this date:
    `07a5bc398dfffdc36ad20a3476348753aa10a322`.
- **Still open:**
  - !1685 (osy): import shm with `VK_EXT_external_memory_host` instead. It is
    required for KosmicKrisp, which lacks `VK_EXT_metal_objects` and the
    MTLBuffer handle type. It needs MoltenVK
    [#2834](https://github.com/KhronosGroup/MoltenVK/pull/2834), which is
    merged to MoltenVK main but not in 1.4.2.
  - !1688: Venus fences through a pipe where there is no eventfd. Without it,
    "fences from render server contexts never retire" on macOS.
  - !1618: Metal texture import into vrend and a scanout API.
- **Two incompatible designs:** the tap patches we apply today are osy's
  earlier, closed series (!1582 and !1583), which use MTLHeap pointers and an
  in-process server. Upstream chose shm fds and an out-of-process server.
  These designs do not merge. We should follow upstream.
- **krunkit/libkrun:** they ship Venus on MoltenVK from an old fork
  (`slp/virglrenderer` tag `0.10.4e-krunkit`, `-Drender-server=false`). That
  fork maps memory with `vkMapMemory` and passes the pointer as an opaque
  handle, which the VMM then maps with `hv_vm_map`. It shows the approach
  works under HVF, but it is not a base we can reuse.

### UTM

UTM 5.0.x pre-releases (v5.0.6, 2026-09-24) ship "Vulkan 1.3 graphics support
for Linux" with Venus. Its notes are directly relevant:

- **No Vulkan desktop.** "Linux desktop rendering in Vulkan does not work due
  to lack of support for indirect draws for geometry shaders. Please configure
  your guest to use the older VirGL Gallium driver."
- **No Vulkan on CoreGL.** "Apple CoreGL backend does not support Vulkan."
  This is our `gl=on` backend.
- **MoltenVK recommended.** MoltenVK is the recommended driver, and the
  KosmicKrisp option now requires macOS 26.

### Guest

- **Driver package:** Arch Linux ARM `extra/vulkan-virtio` 1:26.2.4-1 provides
  the Venus ICD. It is not installed in our image (`guest/packages.txt` has
  only `vulkan-swrast`).
- **Kernel parameters:** Mesa needs `RESOURCE_BLOB`, `HOST_VISIBLE` and
  `CONTEXT_INIT` from the kernel
  ([Mesa venus docs](https://docs.mesa3d.org/drivers/venus.html)). Our 7.2.8
  kernel has all three, and `CONTEXT_INIT` is already negotiated.
- **Blob alignment:** Linux 7.2 added `VIRTIO_GPU_F_BLOB_ALIGNMENT`. Mesa
  !44783 "venus: honor the virtio-gpu blob alignment" was backported to 26.2
  as `d546dcb274f5`, which is an ancestor of the `mesa-26.2.4` tag. So the
  guest's Mesa already rounds blob sizes up once the host offers the feature.
  Without that feature, its notes say `vkCreateInstance` fails with
  `VK_ERROR_OUT_OF_HOST_MEMORY` on 16 KiB hosts.
- **Hyprland:** Hyprland 0.56.2 and aquamarine render with GLES only, so they
  stay on VirGL.
- **Chromium:** Chromium could use ANGLE-on-Vulkan (`--use-angle=vulkan`), as
  ChromeOS does on Venus. Its output would still be a Venus blob composited by
  Hyprland, so it hits the same import gap described in the summary. It is
  unverified on a macOS host.

## MoltenVK or KosmicKrisp

| | MoltenVK | KosmicKrisp (Mesa `kk`) |
|---|---|---|
| Version | 1.4.2 (2026-07-24) | Mesa 26.2.5 (2026-10-14) |
| Conformance | Vulkan 1.4 portability subset | Vulkan 1.3 conformant ([LunarG](https://www.lunarg.com/lunarg-achieves-vulkan-1-3-conformance-with-kosmickrisp-on-apple-silicon/)); main reports 1.4 |
| macOS | 10.15+; fits our 15.0 deployment target | Metal 4, **macOS 26+**, Apple Silicon only |
| Works with upstream vkr main today | Yes (`external_memory_metal` + `metal_objects`, !1602) | No: needs !1685 |
| `VK_EXT_external_memory_host` | Yes; non-host-visible imports need #2834 (unreleased) | Yes |
| Geometry shaders | No upstream (UTM patches its fork) | No |
| License | Apache-2.0 | MIT |
| Packaging | Release tarball: `MoltenVK-macos.tar` | Homebrew `mesa` builds it only on macOS 26 |

**Recommendation: MoltenVK 1.4.2 for the spike and any shipped option.**

- It works with virglrenderer main without extra MRs.
- It respects the app's macOS 15.0 deployment target.
- UTM recommends it.

Revisit KosmicKrisp when !1685 lands and if the app ever requires macOS 26.
Its conformance is better, but neither driver gives Zink a desktop today.

Pin for the spike, recorded from the GitHub release API:

- Asset: `https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar`
- Tag commit: `db66022459ffb663aa2b50f6b018bc2e124f5edf`
- sha256: `f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e`

Verify it on download before use.

## Host memory under HVF

These constraints decide whether a blob is usable in the guest:

- **`hv_vm_map` works only on whole 16 KiB host pages.** `hvf_set_phys_mem`
  silently skips (`add = false`) any section whose guest address or size is not
  16 KiB aligned.
- **A skipped section can crash QEMU.** The guest then traps on every access.
  A SIMD or load-pair access (as in `memcpy`) has no ISV, so QEMU aborts on
  `assert(isv)` in `target/arm/hvf/hvf.c` ("TODO: ISV will be 0 for SIMD or SVE
  accesses"). Unaligned blobs therefore crash the VM.
- **Alignment comes from `VIRTIO_GPU_F_BLOB_ALIGNMENT=16384`.** The guest
  kernel then places blobs on 16 KiB offsets and Mesa rounds their sizes up.
  The hostmem BAR itself is a power-of-two PCI BAR, so it is aligned.
- **`map_fixed` replaces the backing under a live mapping.** It runs
  `mmap(MAP_FIXED)` over `hostmem_mmap`, which HVF already maps as one large
  RAM section. Our own free-page reclaim
  ([memory reclamation](memory-reclamation.md)) deliberately runs
  `hv_vm_unmap`, then `MAP_FIXED`, then `hv_vm_map`, rather than relying on HVF
  to follow a replaced backing. Lucas Amaral's series uses `MAP_FIXED` under
  HVF, which suggests it works, but we have not verified that. The spike must
  test it. The fallback is to disable `map_fixed` on Darwin so every blob
  becomes a subregion with its own `hv_vm_map`.
- **The mapped-sections patch makes the subregion path safe.** A blob subregion
  splits the hostmem background section. If any split piece were unaligned, it
  would never be mapped, and the second unmap that followed was the EXC_GUARD
  crash `qemu-hvf-mapped-sections.patch` fixes. That patch only unmaps sections
  it actually mapped, so it is a prerequisite. With 16 KiB blob alignment, no
  piece should be unaligned.
- **Whether HVF caps the number of mappings is unknown.** Each mapped blob is
  one `hv_vm_map`, and Mesa Venus creates a blob per host-visible
  `VkDeviceMemory`. We have no figure for any limit on the number of mappings.

## Display and the Cocoa GL patches

**The display path does not change in the first phases.** Hyprland keeps
compositing in GL on VirGL, and its scanout stays a VirGL 3D resource that
`qemu-texture-borrowing-11.1.patch` hands to Cocoa as a GL texture.

**The open problem is a Vulkan window.** Its swapchain image is a Venus blob
exported to Hyprland as a dma-buf, and Hyprland imports it through EGL into
VirGL. For that, vrend must turn a Venus blob into a GL texture:

- **The tap's import code needs EGL.** It goes MTLHeap to MTLTexture to EGL
  image, which only works under ANGLE (`gl=es`).
- **Upstream's shm blobs have no GL import at all.**

Candidate fixes:

1. **Copy or client storage.** Upload the shm-backed blob into a GL texture on
   each damage. Apple GL's `GL_APPLE_client_storage` may avoid the copy on
   unified memory. This is unverified.
2. **IOSurface-backed allocations.** Back presentable Venus allocations with
   IOSurface, so that both CGL (`CGLTexImageIOSurface2D`) and Metal can share
   them. This is new virglrenderer work.
3. **An opt-in `gl=es` (ANGLE) display for Venus sessions.** This regresses the
   browser fixes recorded in [performance](performance.md).
4. **Port UTM's Metal scanout.** This means QEMU RFC patches 5 and 7 plus
   virglrenderer !1618, and means rewriting our Cocoa display around Metal.

None of these is in scope until the spike passes. Blob scanout is not needed
while the compositor is on VirGL.

## Prerequisites

- Mac on macOS 15 or later for MoltenVK. The development Mac runs macOS 26.6.2
  on an M3 Max, so both drivers are possible there.
- Guest kernel 7.2 or later and Mesa 26.2.4 or later. Both are already in the
  image.
- A QEMU patch offering `VIRTIO_GPU_F_BLOB_ALIGNMENT`, from Lucas Amaral v5
  4/4 or UTM.
- virglrenderer main, with our VirGL patch stack rebased onto it. This is the
  largest single task, because the tap's 21 patches and
  `virgl-native-opengl.patch` target 1.3.0, and `virglrenderer-macos-unified.patch`
  conflicts with !1600 and !1602.

## Phased plan

### Phase 1: spike (developer build, not shipped)

Goal: run `vulkaninfo` and an offscreen Vulkan workload in the guest without
destabilizing the VirGL desktop.

1. **Build a separate runtime** with `macos/build-qemu-gpu-runtime.sh`
   parameterized by a new `OMARCHY_RUNTIME_VENUS=1` build switch (default off).
   It differs from the normal runtime as follows:
   - **virglrenderer:** source pinned to main
     `07a5bc398dfffdc36ad20a3476348753aa10a322` plus !1688, instead of 1.3.0.
     Only the minimum VirGL patches needed for the desktop to render are
     rebased (`virglrenderer-macos-unified.patch` is dropped). Configure with
     `-Dvenus=true -Drender-server-worker=process`.
   - **MoltenVK:** the 1.4.2 `MoltenVK-macos.tar` pin above.
     `MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib` is staged as the Vulkan
     library. virglrenderer `dlopen`s `libvulkan.1.dylib`, so either bundle the
     Khronos loader or point virglrenderer at MoltenVK directly.
   - **QEMU patch `qemu-virtio-gpu-blob-alignment.patch`:** advertises
     `VIRTIO_GPU_F_BLOB_ALIGNMENT` with `qemu_real_host_page_size()`.
   - **QEMU patch `qemu-virtio-gpu-darwin-map-fixed.patch`, kept only if
     needed:** under HVF it skips `map_fixed` so blobs use subregions.
2. **Run the spike VM by hand**, not through the app. Use the dev runtime's
   `qemu-system-aarch64` with the launcher's arguments and
   `-device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,blob=true,hostmem=4G,venus=true`.
   Set `RENDER_SERVER_EXEC_PATH` to the staged `virgl_render_server`. Use a
   disposable APFS clone of a factory disk, never a personal VM.
3. **Prepare the guest** with `pacman -S vulkan-virtio vulkan-tools vkmark`,
   then:
   - Run `vulkaninfo --summary` and expect `Virtio-GPU Venus (Apple M3 Max)`.
   - Run `vkcube --wsi display` or a headless vkmark.
   - Run `llama-bench` with Vulkan.
4. **Check `-resource_blob`/`-host_visible`/`-blob_alignment` all flip to `+`**
   in `dmesg`, and that capset 4 appears.

**Go/no-go: the spike passes only if all of these hold.**

- `vulkaninfo` lists the Venus device, and a 30-minute offscreen vkmark or
  `llama-bench` loop finishes. No QEMU abort or EXC_GUARD, no guest
  `*ERROR* response`, and no hung fences.
- Hyprland, Chromium WebGL and Alacritty on VirGL show no regression with
  `blob=true,hostmem=,venus=true` enabled. That means the same glyph and color
  checks as [performance](performance.md), and no new
  `qemu-guest-errors.log` entries.
- Vulkan compute beats the guest's CPU path by at least 1.5× on
  `llama-bench` pp512. The krunkit reference is about 1.3× CPU and about 57%
  of native Metal on an M2 Max
  ([llama.cpp #12985](https://github.com/ggml-org/llama.cpp/discussions/12985)).
- Rebasing the VirGL patches onto virglrenderer main keeps
  `macos/Tests/virgl/run-regressions.py` and the tap's driver regressions
  green.

If any of these fail, stop and keep this document as the record. Separately,
whether a Vulkan window appears in Hyprland decides whether
[Display](#display-and-the-cocoa-gl-patches) work is worth starting. It is not
a spike criterion.

### Phase 2: runtime build changes

- **`macos/build-qemu-gpu-runtime.sh`:** add pinned sources:
  - virglrenderer main commit, replacing `virgl_source_root=virglrenderer-1.3.0`
    once the rebased patch stack is the default for both paths.
  - The MoltenVK tarball and its sha256.
  - Optionally the Khronos `Vulkan-Loader` tag.

  Add Venus configure options. Build `virgl_render_server` with
  `-Dlibexecdir` inside the runtime prefix.
- **Move our virglrenderer patches into the repo** under `macos/patches/`
  (`virgl-*.patch`), so they no longer depend on the third-party tap at v1.0.42.
  Drop `virglrenderer-macos-unified.patch` and the two `venus-*` tap patches.
- **`macos/patches/`:** add the two QEMU patches from Phase 1 with sha256
  entries, applied after `qemu-hvf-mapped-sections.patch`. Drop them when
  Lucas Amaral's series lands upstream.
- **`macos/prepare-qemu-gpu-runtime.sh` and `macos/runtime-files.txt`:** stage
  `libexec/virgl_render_server` and `lib/libMoltenVK.dylib` (plus the loader
  and an ICD JSON if used), with relocation and signing.
  - The render server is spawned by QEMU, so it needs its own signature but no
    hypervisor entitlement.
  - Check that `macos/verify-macos-compatibility.sh` accepts MoltenVK's minimum
    OS.
- **`RENDER_SERVER_EXEC_PATH`:** the compiled-in value would point at the
  scratch build. Either have `run-qemu-gpu.sh` export it to the bundled path,
  or patch virglrenderer to resolve it relative to the dylib.

### Phase 3: guest changes

- Add `vulkan-virtio` to `guest/packages.txt` and refresh
  `guest/packages.lock.json`. It should be inert under VirGL-only QEMU, because
  Mesa Venus finds no Venus capset and exposes no device. Mesa 26.2.5 also
  skips virtio-gpu devices without 3D (`29d21ed7307c`). Confirm this in the
  spike.
- Do not set `MESA_LOADER_DRIVER_OVERRIDE=zink` or change Hyprland's renderer.
- Optionally ship a Chromium flag file for `--use-angle=vulkan`, only behind the
  same opt-in and only after the display import exists.

### Phase 4: launcher opt-in

- `macos/run-qemu-gpu.sh`: read `OMARCHY_QEMU_GPU_VENUS` (default `0`; values
  `0` or `1`, checked like `OMARCHY_QEMU_GPU_IMMERSIVE`). With `1`:
  - Require `venus=` and `blob=` in `gpu_help` and the staged render server.
  - Append `,blob=true,hostmem=${OMARCHY_QEMU_GPU_HOSTMEM_MIB:-4096}M,venus=true`
    to `gpu_device`.
  - Export `RENDER_SERVER_EXEC_PATH`.
  - Add the Venus device to the `qemu-args-lint.sh` expectations, and count
    `hostmem` against the host-memory headroom check. It reserves address
    space but only commits the memory that blobs actually use.
- The bundle contract's `graphics` record (`guestRenderer: "virgl"`) stays
  as it is. Venus is an additional context type, not a different guest
  renderer.
- The app UI exposes nothing until Phase 5 passes.

### Phase 5: validation and benchmarks

Use `scripts/profile-process.py` on QEMU plus the render-server PID, in a
disposable guest at a fixed resolution. Compare VirGL-only against
VirGL+Venus for:

- idle CPU and memory;
- `vkmark` offscreen;
- `llama-bench` (Vulkan vs CPU, plus native Metal on the host);
- `glmark2-es2-wayland` on VirGL, to show the desktop is unchanged.

Record the results in [performance](performance.md) in its existing style.

## Risks and unknowns

- **Patch rebase:** our VirGL fixes target 1.3.0 plus the tap. Rebasing onto
  main touches the same `vrend_renderer.c` areas and could regress browser
  text and color. This is the biggest cost, and it hits the default path too
  unless the Venus runtime stays separate.
- **Unreleased upstream:** both virglrenderer main and the QEMU series are
  moving. We would pin commits, not releases.
- **HVF coherence for `MAP_FIXED` over a mapped range** is unverified. The
  fallback is subregions.
- **The number of HVF mappings** for many small blobs is unknown.
- **No Vulkan windows on `gl=on`:** there is no import path today. UTM states
  that CoreGL does not support Vulkan.
- **No geometry shaders in MoltenVK,** which rules out Zink desktops and
  DXVK.
- **The render-server process** is a new signed executable in the bundle and a
  new crash domain. QEMU issue
  [#3156](https://gitlab.com/qemu-project/qemu/-/issues/3156) covers
  sandboxing conflicts.
- **`blob=true` changes the VirGL path as well.** Guest virgl could start using
  host-visible blobs. Apple OpenGL 4.1 lacks `GL_ARB_buffer_storage`, so vrend
  should not offer mappable GL blobs, but this needs confirming in the spike.
- **Lavapipe interplay:** `vulkan-swrast` (lavapipe) stays installed, so
  applications may pick it over Venus. Use `VK_DRIVER_FILES` in tests.

## Not verified

- Whether UTM's current virglrenderer fork branch matches !1685/!1688.
- Whether MoltenVK 1.4.2 alone satisfies !1602 on macOS 15. It was reported
  working on an M4 Max, OS version not stated.
- Any Chromium, ANGLE-Vulkan or Zink result on a macOS Venus host.
- Performance of KosmicKrisp under Venus.
