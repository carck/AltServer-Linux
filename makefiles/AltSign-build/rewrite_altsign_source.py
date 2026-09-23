#!/usr/bin/python3

import re
import sys

F = sys.argv[1]

with open(F, 'rb') as f:
    content = f.read()

content = re.sub(br'L("([^"\\]|\\.)*")', br'U(\1)', content)
content = content.replace(b'std::wstring', b'std::string')
content = content.replace(b'boost/filesystem.hpp', b'filesystem')
content = content.replace(b'boost::filesystem', b'std::filesystem')

content = content.replace(b'"%FT%T%z"', b'"%Y-%m-%dT%H:%M:%SZ"')
content = content.replace(b'localtime(', b'gmtime(')

content = content.replace(b'winsock2.h', b'WinSock2.h')
content = content.replace(b'"akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0"', b'"AuthKit/1 (Macintosh; OS X 26.5.2) (com.apple.dt.Xcode/26.0)"')
if b'std::vector' in content and b'#include <vector>' not in content:
    content = b'#include <vector>\n' + content
content = content.replace(
    b'plist_from_xml((const char *)decryptedData->data(), (int)decryptedData->size(), &decryptedPlist);',
    b'plist_format_t decryptedFormat = PLIST_FORMAT_NONE;\n'
    b'\tplist_err_t decryptedPlistError = plist_from_memory((const char *)decryptedData->data(), (int)decryptedData->size(), &decryptedPlist, &decryptedFormat);')
content = content.replace(
    b'odslog("ERROR: Could not parse decrypted login response plist!");',
    b'odslog("ERROR: Could not parse decrypted login response plist (error=" << (int)decryptedPlistError << ", format=" << (int)decryptedFormat << ", size=" << decryptedData->size() << " bytes).");')

# --- Give every GrandSlam request its own TCP connection -------------------------------
#
# AppleAPI is a process-wide singleton holding ONE _gsaClient, built in the constructor.
# gsaClient() hands back a copy sharing the same cpprestsdk impl and therefore the same asio
# connection pool, and the second GSA request is issued from a .then() continuation the instant
# the first completes -- textbook keep-alive reuse. No Connection header is ever set.
#
# Since ~2026-09 Apple's GrandSlam edge refuses the SECOND request on a reused connection.
# Observed here: request 1 -> 200, request 2 -> 429, identically on the first-ever attempt and
# again 28 minutes later. Positional and non-cumulative, which is not how volume throttling
# behaves. Every header and all ten anisette values are byte-identical between the two requests,
# so the only things that differ are the plist body and the connection position.
#
# This is the same fix as rileytestut/AltSign PR #52 ("Use a separate connection for each
# GrandSlam request", shipped in AltServer 1.7.6) and nab138/iloader 2.3.3 ("Disabled reqwest
# pooling to alleviate http 429 from grandslam"). Note iloader already carried the com.apple.akd
# client-info fix when it hit this, which is why that fix REVEALS the 429 rather than causing it.
#
# Cost: one extra TLS handshake per GrandSlam request, a handful of times per sign-in.
_gsa_old = (
    b'web::http::client::http_client AppleAPI::gsaClient()\n'
    b'{\n'
    b'\treturn this->_gsaClient;\n'
    b'}\n'
)
_gsa_new = (
    b'web::http::client::http_client AppleAPI::gsaClient()\n'
    b'{\n'
    b'\t// Patched by rewrite_altsign_source.py: a FRESH client per call, so each GrandSlam\n'
    b'\t// request opens its own connection instead of reusing the singleton\'s pooled one.\n'
    b'\t// Apple 429s the second request on a reused connection. See the note in the rewriter.\n'
    b'\thttp_client_config gsaConfig;\n'
    b'\tgsaConfig.set_validate_certificates(false);\n'
    b'\treturn web::http::client::http_client(U("https://gsa.apple.com"), gsaConfig);\n'
    b'}\n'
)
if F.endswith('AppleAPI.cpp'):
    if content.count(_gsa_old) != 1:
        sys.stderr.write(
            "rewrite_altsign_source.py: gsaClient() connection patch matched %d times, expected 1.\n"
            "  upstream AppleAPI.cpp changed; re-check before removing this guard.\n"
            % content.count(_gsa_old))
        sys.exit(1)
    content = content.replace(_gsa_old, _gsa_new)

sys.stdout.buffer.write(content)
