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

if F.endswith('AppleAPI+Authentication.cpp'):
    content, replacements = re.subn(
        br'(uri_builder builder\(U\("/grandslam/GsService2"\)\);\s*http_request request\(methods::POST\);.*?for \(auto& pair : headers\)\s*\{.*?\}\s*)auto task = this->gsaClient\(\)\.request\(request\)',
        lambda match: match.group(1) + b'http_client_config config;\n\tconfig.set_validate_certificates(false);\n\tauto gsaClient = std::make_shared<http_client>(U("https://gsa.apple.com"), config);\n\tauto task = gsaClient->request(request)',
        content,
        count=1,
        flags=re.S,
    )
    if replacements != 1:
        print('Unable to disable GrandSlam connection reuse in SendAuthenticationRequest', file=sys.stderr)
        sys.exit(1)

sys.stdout.buffer.write(content)
