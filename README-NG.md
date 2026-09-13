# AltServer-Linux-NG

A fork of [NyaMisty/AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux) that installs and
signs apps for **iOS 26.4 / 27** devices over Wi-Fi. Upstream has been unmaintained since 2023
(only automated keepalive commits) and its v0.0.5 binary fails on modern iOS for two independent
reasons, both fixed here.

Layout:

- This repository, branch `ng`: the AltServer-Linux tree.
- Submodule `upstream_repo` = [jaakkopalvaila/AltServer-Windows](https://github.com/jaakkopalvaila/AltServer-Windows),
  branch `ng-fixes`: vendored AltSign + ldid with the signing and sign-in fixes.
- Submodule `libraries/libimobiledevice` = [jaakkopalvaila/libimobiledevice](https://github.com/jaakkopalvaila/libimobiledevice),
  branch `ng-fixes`: netmuxd address-format fix.
- All other submodules track their upstream repositories unchanged.

Clone with `git clone --recursive -b ng https://github.com/jaakkopalvaila/AltServer-Linux`.

## Fix 1 — code signature rejected by iOS 26.4+

### Symptom

`AltStore` installs successfully but the app flashes and closes. `idevicesyslog` shows:

```
kernel  AMFI: cmsBlobVerifyWithAgilityHash failed ... Unrecoverable CT signature issue
launchd Bad executable (85)
```

### Root cause

Signing is done by a copy of `ldid` vendored inside AltServer-Windows, pinned to a 2022 commit.
That version writes the CMS *hash agility* signed attribute (OID `1.2.840.113635.100.9.2`) with the
SHA-256 code directory hash **truncated to 20 bytes**. Apple requires the **full 32 bytes**, so
CoreTrust cannot match the attribute against the alternate code directory and rejects the signature.

Measured on a test binary signed with each version:

| | old ldid (2022) | new ldid |
| --- | --- | --- |
| entries in the `9.2` attribute | 1 | 2 |
| SHA-1 entry | absent | 20 bytes, matches primary code directory |
| SHA-256 entry | **20 bytes, truncated** | **32 bytes, exact match** |
| designated requirement | empty | generated |

The empty designated requirement was a second defect flagged in upstream issue #131.

### Fix

Upstream Riley Testut already fixed this: AltServer for Windows 1.7.4 (2026-03-24) shipped
*"Fixed apps crashing on launch on iOS 26.4"* via commit `62a7a2b`
*"[ldid] Updates ldid to match AltStore + AltServer macOS' version"*. That commit lives on the
branches `26.4_fix` / `1.7.4` / `develop` of rileytestut/AltServer-Windows, which the Linux fork
never picked up.

This fork takes `ldid/ldid.cpp` and `ldid/ldid.hpp` from commit `2e6783d` and adapts the caller:

- `AltSign/Signer.cpp` – the new `ldid::Sign` takes a single `ldid::Progress` object instead of two
  `Functor` callbacks.
- `AltSign/Signer.cpp` – the new `DiskFolder` asserts on a missing trailing path separator, so the
  bundle path gets a `"/"`. Upstream appends a Windows backslash here; the Linux source rewriter
  does not translate backslashes, so the forward slash is required.

The new ldid compiles against the existing LibreSSL toolchain with no errors, so the OpenSSL 3
upgrade that accompanied it on Windows is not needed.

## Fix 2 — Apple blocks the sign-in

### Symptom

Since early September 2026, `gsa.apple.com` answers **HTTP 503** with an HTML page to every
request whose `X-Mme-Client-Info` header contains the substring `com.apple.dt.Xcode`. This broke
AltServer, AltStore and SideStore sign-in simultaneously.

### Fix

Three changes, mirroring altstoreio/AltStore#1790 and rileytestut/AltSign #51 / #52:

- `src/AnisetteDataManager.cpp` – replace every `com.apple.dt.Xcode` with `com.apple.akd` in the
  client info string returned by the anisette server, before the `AnisetteData` object is built.
  All four call sites that send the header read it from that object, so one substitution covers
  them all. This also means an out-of-date anisette server no longer matters.
- `AltSign/AppleAPI+Authentication.cpp` – GrandSlam `User-Agent` becomes
  `AuthKit/1 (Macintosh; OS X 26.5.2) (com.apple.dt.Xcode/26.0)`. The block applies only to the
  client info header, so the Xcode token is still allowed here.
- `AltSign/AppleAPI.cpp` – `gsaClient()` returns a brand new `http_client` on every call rather
  than a cached member, so no GSA request travels over a reused keep-alive connection. The bundled
  cpprestsdk has no `http_client_config::set_keep_alive()`, so a fresh connection pool per request
  is how connection reuse is avoided.

## Building

Builds run in the prebuilt upstream Alpine image. On an Apple Silicon Mac, Rosetta runs the amd64
container at native speed and a clean build takes about 30 seconds.

```bash
cd src
mkdir -p build
docker run --rm --platform linux/amd64 -v "$PWD:/workdir" -w /workdir \
  ghcr.io/nyamisty/altserver_builder_alpine_amd64:latest \
  bash -c 'cd build && make -f ../Makefile -j8'
```

The result is a statically linked `build/AltServer-x86_64`. Other architectures use the
`altserver_builder_alpine_{aarch64,armv7,i386}` images.

Sanity-check that both fixes are present:

```bash
strings build/AltServer-x86_64 | grep -c "missing path separator"   # new ldid  -> 1
strings build/AltServer-x86_64 | grep -c "Sanitized client info"    # login fix -> 1
```

## Running

```bash
USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 \
ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969 \
./AltServer-x86_64 -d -u <UDID> -a <apple-id> -p <password> AltStore.ipa
```

`-d` enables debug output. Wi-Fi installs need netmuxd listening on that address (see Fix 3).

To check sign-in without real credentials, run it with a throwaway account. HTTP 503 means Apple is
still blocking; a GSA error such as `-20101` or `-20209` means the request reached the service.

## Fix 3 — netmuxd address format

netmuxd >= 0.3 reports the device `NetworkAddress` in Linux sockaddr layout (a little-endian
`sa_family_t` first: `02 00` = AF_INET, `0a 00` = AF_INET6). The bundled 2022 libimobiledevice
assumed the BSD layout (byte 0 = `sa_len`, byte 1 = family) and failed with
`Unsupported address family 0x00`.

`libraries/libimobiledevice/src/idevice.c` now detects both layouts, so `USBMUXD_SOCKET_ADDRESS`
can point straight at netmuxd. A BSD-format proxy in front of netmuxd keeps working as well.
