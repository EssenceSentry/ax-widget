#!/usr/bin/env python3
"""Plan by default. --install creates an explicitly approved local signing identity."""
import argparse
import os
import pathlib
import subprocess
import tempfile

NAME = "AX Widget Local Signing"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--install", action="store_true", help="Add the certificate and private key to the login Keychain")
args = parser.parse_args()
plan = (
    f"Create {NAME!r}: RSA 3072, SHA-256, code-signing use only, valid for 10 years.\n"
    "Import its certificate and private key into this user's login Keychain.\n"
    "Permit /usr/bin/codesign to use the key; restrict certificate trust to code signing.\n"
    "Remove temporary key files. No Apple account, cloud upload, or system-wide trust changes.\n"
    "Future local builds/installations reuse this identity; CI stays ad hoc."
)
print(plan)
if not args.install:
    print("Plan only. Run with --install only after approving the Keychain changes.")
    raise SystemExit(0)

def run(*command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, capture_output=True)

keychain = pathlib.Path.home() / "Library/Keychains/login.keychain-db"
existing = subprocess.run(
    ["security", "find-certificate", "-c", NAME, str(keychain)], capture_output=True
)
if existing.returncode == 0:
    raise SystemExit("A certificate with this name already exists. Reuse or inspect it; refusing to replace its identity.")
os.umask(0o077)
with tempfile.TemporaryDirectory(prefix="ax-widget-signing-") as temporary:
    folder = pathlib.Path(temporary)
    key = folder / "private.pem"
    certificate = folder / "certificate.pem"
    config = folder / "certificate.cnf"
    config.write_text("""[req]
distinguished_name = dn
prompt = no
x509_extensions = signing
[dn]
CN = AX Widget Local Signing
O = AX Widget Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
""")
    run("openssl", "genrsa", "-out", str(key), "3072")
    run("openssl", "req", "-new", "-x509", "-sha256", "-days", "3650", "-key", str(key),
        "-out", str(certificate), "-config", str(config))
    run("security", "import", str(key), "-k", str(keychain), "-T", "/usr/bin/codesign")
    run("security", "import", str(certificate), "-k", str(keychain))
    run("security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", str(keychain), str(certificate))
identities = run("security", "find-identity", "-v", "-p", "codesigning").stdout
matching = [line.strip() for line in identities.splitlines() if f'"{NAME}"' in line]
if len(matching) != 1:
    raise SystemExit("The identity was imported but is not uniquely usable for code signing. Inspect it in Keychain Access before proceeding.")
print("Ready:", matching[0])
