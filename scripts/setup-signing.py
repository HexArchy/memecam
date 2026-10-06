#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt", "cryptography", "requests"]
# ///
"""Provision local development signing for MemeCam via the App Store Connect API.

Creates (idempotently): this Mac as a device, the two bundle IDs with the System
Extension capability, an Apple Development certificate (private key stays in the
login keychain), and two macOS development provisioning profiles.

Output: ~/.memecam-signing/{signing.env, MemeCam.provisionprofile, CameraExtension.provisionprofile}
Secrets are never printed.

Usage: scripts/setup-signing.py [path/to/appstoreconnect.env] [--revoke <serial>] [--distribution]
  --distribution  Developer ID certificate + MAC_APP_DIRECT profiles (release.env) for
                  notarized builds that run on any Mac (scripts/build-app.sh --release).
  --import-cert   path to the Developer ID .cer downloaded from the portal (Account Holder
                  flow: the script writes the CSR when the API refuses to issue it).
"""

import base64
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

import jwt
import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

APP_ID = "com.hexarch.memecam"
EXT_ID = "com.hexarch.memecam.camera-extension"
OUT = pathlib.Path.home() / ".memecam-signing"
API = "https://api.appstoreconnect.apple.com/v1"
WWDR_G3 = "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
DEVID_G2 = "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"


def load_env(path: pathlib.Path) -> dict[str, str]:
    env = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^\s*([A-Z_]+)\s*=\s*\"?(.*?)\"?\s*$", line)
        if m:
            env[m.group(1)] = m.group(2)
    return env


class ASC:
    def __init__(self, key_id: str, issuer: str, key: str):
        self.key_id, self.issuer, self.key = key_id, issuer, key

    def _headers(self):
        now = int(time.time())
        token = jwt.encode(
            {"iss": self.issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
            self.key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})
        return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    def raw(self, method: str, path: str, **kw) -> requests.Response:
        return requests.request(method, API + path, headers=self._headers(), timeout=60, **kw)

    def call(self, method: str, path: str, **kw):
        r = self.raw(method, path, **kw)
        if r.status_code >= 400:
            errs = r.json().get("errors", [{}]) if r.content else [{}]
            detail = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errs)
            sys.exit(f"ASC {method} {path} -> {r.status_code}: {detail}")
        return r.json() if r.content else {}


def step(msg: str):
    print(f"• {msg}", flush=True)


def mac_udid() -> str:
    out = subprocess.run(["system_profiler", "SPHardwareDataType"], capture_output=True, text=True).stdout
    m = re.search(r"Provisioning UDID:\s*(\S+)", out)
    if not m:
        sys.exit("Could not read Provisioning UDID")
    return m.group(1)


def ensure_device(asc: ASC) -> str:
    udid = mac_udid()
    found = asc.call("GET", f"/devices?filter[udid]={udid}")["data"]
    if found:
        step(f"device registered ({found[0]['attributes']['name']})")
        return found[0]["id"]
    step("registering this Mac as a device")
    body = {"data": {"type": "devices", "attributes": {
        "name": f"MemeCam {os.uname().nodename}", "platform": "MAC_OS", "udid": udid}}}
    return asc.call("POST", "/devices", json=body)["data"]["id"]


def ensure_bundle(asc: ASC, identifier: str, name: str, capabilities: list[str]) -> str:
    items = asc.call("GET", f"/bundleIds?filter[identifier]={identifier}&limit=200")["data"]
    exact = [b for b in items if b["attributes"]["identifier"] == identifier]
    if exact:
        bid = exact[0]["id"]
        step(f"bundle id {identifier} exists")
    else:
        step(f"creating bundle id {identifier}")
        body = {"data": {"type": "bundleIds", "attributes": {
            "identifier": identifier, "name": name, "platform": "MAC_OS"}}}
        bid = asc.call("POST", "/bundleIds", json=body)["data"]["id"]
    have = {c["attributes"]["capabilityType"]
            for c in asc.call("GET", f"/bundleIds/{bid}/bundleIdCapabilities")["data"]}
    for cap in capabilities:
        if cap not in have:
            step(f"  enabling {cap}")
            asc.call("POST", "/bundleIdCapabilities", json={"data": {
                "type": "bundleIdCapabilities", "attributes": {"capabilityType": cap},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}})
    return bid


def local_identities() -> dict[str, str]:
    """SHA-1 -> name for valid code-signing identities in the keychain."""
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
    return {m.group(1): m.group(2) for m in re.finditer(r"\)\s+([0-9A-F]{40})\s+\"(.+?)\"", out)}


def import_identity(key, cert: x509.Certificate, ca_url: str = WWDR_G3):
    """Imports key + cert into the login keychain via a throwaway-password PKCS#12.
    macOS `security` only understands legacy PKCS#12 encryption (3DES + SHA-1 MAC)."""
    password = base64.b64encode(os.urandom(18)).decode()
    enc = (serialization.PrivateFormat.PKCS12.encryption_builder()
           .kdf_rounds(50000)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
           .hmac_hash(hashes.SHA1())
           .build(password.encode()))
    p12 = pkcs12.serialize_key_and_certificates(b"MemeCam Dev", key, cert, None, enc)
    with tempfile.TemporaryDirectory() as tmp:
        p = pathlib.Path(tmp) / "dev.p12"
        p.write_bytes(p12)
        r = subprocess.run(["security", "import", str(p), "-P", password, "-T", "/usr/bin/codesign",
                            "-k", str(pathlib.Path.home() / "Library/Keychains/login.keychain-db")],
                           capture_output=True, text=True)
        if r.returncode != 0 and "already exists" not in r.stderr:
            sys.exit(f"security import failed: {r.stderr.strip()}")
        ca = pathlib.Path(tmp) / "ca.cer"
        ca.write_bytes(requests.get(ca_url, timeout=60).content)
        subprocess.run(["security", "import", str(ca)], capture_output=True)  # ok if already present


def ensure_certificate(asc: ASC, types: tuple[str, ...] = ("DEVELOPMENT",), label: str = "Apple Development",
                       pending_name: str = "pending-key.pem", ca_url: str = WWDR_G3) -> tuple[str, str]:
    """Returns (ASC certificate id, SHA-1). Reuses a cert whose key is already local."""
    local = local_identities()
    certs = asc.call("GET", f"/certificates?filter[certificateType]={','.join(types)}&limit=200")["data"]
    parsed = [(c["id"], x509.load_der_x509_certificate(base64.b64decode(c["attributes"]["certificateContent"])))
              for c in certs]
    for cid, cert in parsed:
        sha1 = cert.fingerprint(hashes.SHA1()).hex().upper()
        if sha1 in local:
            step(f"reusing certificate “{local[sha1]}”")
            return cid, sha1

    # A key from an interrupted run: finish importing its certificate instead of minting a new one.
    pending = OUT / pending_name
    if pending.exists():
        key = serialization.load_pem_private_key(pending.read_bytes(), password=None)
        pub = key.public_key().public_numbers()
        for cid, cert in parsed:
            if cert.public_key().public_numbers() == pub:
                step("finishing import of certificate from previous run")
                import_identity(key, cert, ca_url)
                pending.unlink()
                return cid, cert.fingerprint(hashes.SHA1()).hex().upper()
    else:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        OUT.mkdir(mode=0o700, exist_ok=True)
        pending.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                              serialization.PrivateFormat.PKCS8,
                                              serialization.NoEncryption()))
        pending.chmod(0o600)

    step(f"creating {label} certificate")
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "MemeCam Dev"),
                                    x509.NameAttribute(NameOID.EMAIL_ADDRESS, "dev@hexarch.local")]))
           .sign(key, hashes.SHA256()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    for cert_type in types:
        r = asc.raw("POST", "/certificates", json={"data": {"type": "certificates", "attributes": {
            "certificateType": cert_type, "csrContent": csr_pem}}})
        if r.status_code not in (400, 422):  # unsupported type → try the next one
            break
    if r.status_code == 403 and "Account Holder" in r.text:
        # Developer ID certificates can only be issued to the Account Holder in the browser.
        # The private key stays here (pending key); the user uploads this CSR and brings back the .cer.
        csr_path = OUT / "MemeCam-DeveloperID.certSigningRequest"
        csr_path.write_text(csr_pem)
        sys.exit(f"""
Apple only lets the Account Holder create {label} certificates (not API keys).
1. Open https://developer.apple.com/account/resources/certificates/add
2. Choose "Developer ID Application" (G2 Sub-CA) → Continue
3. Upload {csr_path}
4. Download the certificate (.cer), then run:
   uv run --script scripts/setup-signing.py --distribution --import-cert ~/Downloads/developerID_application.cer
""")
    if r.status_code == 409:
        print(f"\nApple's limit for {label} certificates is reached on this account:", file=sys.stderr)
        for c in certs:
            a = c["attributes"]
            print(f"  serial {a['serialNumber']}  “{a.get('displayName') or a.get('name')}”  "
                  f"expires {a['expirationDate'][:10]}  (private key NOT on this Mac)", file=sys.stderr)
        sys.exit("\nIf it is the orphan from an interrupted run (or you no longer use it), revoke it and retry:\n"
                 "  uv run --script scripts/setup-signing.py --revoke <serial>")
    if r.status_code >= 400:
        sys.exit(f"ASC POST /certificates -> {r.status_code}: {r.text[:300]}")
    data = r.json()["data"]
    cert = x509.load_der_x509_certificate(base64.b64decode(data["attributes"]["certificateContent"]))
    import_identity(key, cert, ca_url)
    pending.unlink()
    return data["id"], cert.fingerprint(hashes.SHA1()).hex().upper()


def ensure_profile(asc: ASC, name: str, bundle_id: str, cert_id: str, device_id: str | None,
                   profile_type: str = "MAC_APP_DEVELOPMENT") -> bytes:
    for p in asc.call("GET", f"/profiles?filter[name]={requests.utils.quote(name)}")["data"]:
        step(f"  replacing old profile “{name}”")
        asc.call("DELETE", f"/profiles/{p['id']}")
    step(f"creating profile “{name}”")
    data = asc.call("POST", "/profiles", json={"data": {
        "type": "profiles",
        "attributes": {"name": name, "profileType": profile_type},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            **({"devices": {"data": [{"type": "devices", "id": device_id}]}} if device_id else {}),
        }}})["data"]
    return base64.b64decode(data["attributes"]["profileContent"])


def revoke(asc: ASC, serial: str):
    certs = asc.call("GET", "/certificates?filter[certificateType]=DEVELOPMENT&limit=200")["data"]
    match = [c for c in certs if c["attributes"]["serialNumber"].upper() == serial.upper()]
    if not match:
        sys.exit(f"No Development certificate with serial {serial}")
    asc.call("DELETE", f"/certificates/{match[0]['id']}")
    step(f"revoked certificate {serial}")


def main():
    args = sys.argv[1:]
    revoke_serial = None
    distribution = "--distribution" in args
    if distribution:
        args.remove("--distribution")
    import_cert = None
    if "--import-cert" in args:
        i = args.index("--import-cert")
        import_cert = pathlib.Path(args[i + 1]).expanduser()
        del args[i:i + 2]
    if "--revoke" in args:
        i = args.index("--revoke")
        revoke_serial = args[i + 1]
        del args[i:i + 2]
    env_path = pathlib.Path(args[0] if args else
                            "~/Workspace/vps/porovnu/secrets/appstoreconnect.env").expanduser()
    env = load_env(env_path)
    key_id, issuer, team = env.get("ASC_KEY_ID"), env.get("ASC_ISSUER_ID"), env.get("APPLE_TEAM_ID")
    if not (key_id and issuer and team):
        sys.exit(f"{env_path}: need ASC_KEY_ID, ASC_ISSUER_ID, APPLE_TEAM_ID")
    candidates = [pathlib.Path(env.get("ASC_KEY_PATH", "")).expanduser(),
                  env_path.parent / f"AuthKey_{key_id}.p8"]
    key_file = next((p for p in candidates if p.is_file()), None)
    if not key_file:
        sys.exit(f"AuthKey_{key_id}.p8 not found next to {env_path}")
    asc = ASC(key_id, issuer, key_file.read_text())

    if revoke_serial:
        revoke(asc, revoke_serial)
    app = ensure_bundle(asc, APP_ID, "MemeCam", ["SYSTEM_EXTENSION_INSTALL"])
    ext = ensure_bundle(asc, EXT_ID, "MemeCam Camera Extension", [])

    if import_cert:
        pending = OUT / "pending-devid-key.pem"
        if not pending.exists():
            sys.exit(f"{pending} not found — the .cer must match the CSR this script generated.")
        key = serialization.load_pem_private_key(pending.read_bytes(), password=None)
        raw = import_cert.read_bytes()
        cert = (x509.load_pem_x509_certificate(raw) if raw.startswith(b"-----")
                else x509.load_der_x509_certificate(raw))
        if cert.public_key().public_numbers() != key.public_key().public_numbers():
            sys.exit("This certificate does not match the CSR generated by this script.")
        step("importing Developer ID certificate into the login keychain")
        import_identity(key, cert, DEVID_G2)
        pending.unlink()

    if distribution:
        # Developer ID: runs on any Mac after notarization; profiles have no device list.
        cert_id, sha1 = ensure_certificate(asc, ("DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"),
                                           "Developer ID Application", "pending-devid-key.pem", DEVID_G2)
        OUT.mkdir(mode=0o700, exist_ok=True)
        (OUT / "MemeCam-DeveloperID.provisionprofile").write_bytes(
            ensure_profile(asc, "MemeCam Developer ID", app, cert_id, None, "MAC_APP_DIRECT"))
        (OUT / "CameraExtension-DeveloperID.provisionprofile").write_bytes(
            ensure_profile(asc, "MemeCam Camera Extension Developer ID", ext, cert_id, None, "MAC_APP_DIRECT"))
        (OUT / "release.env").write_text(f"TEAM_ID={team}\nSIGN_IDENTITY={sha1}\n")
        step(f"done → {OUT}/release.env  (Developer ID {sha1[:8]}…)")
        return

    device = ensure_device(asc)
    cert_id, sha1 = ensure_certificate(asc)

    OUT.mkdir(mode=0o700, exist_ok=True)
    (OUT / "MemeCam.provisionprofile").write_bytes(
        ensure_profile(asc, "MemeCam Dev", app, cert_id, device))
    (OUT / "CameraExtension.provisionprofile").write_bytes(
        ensure_profile(asc, "MemeCam Camera Extension Dev", ext, cert_id, device))
    (OUT / "signing.env").write_text(f"TEAM_ID={team}\nSIGN_IDENTITY={sha1}\n")
    step(f"done → {OUT}  (team {team}, identity {sha1[:8]}…)")


if __name__ == "__main__":
    main()
