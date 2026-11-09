#!/usr/bin/env python3 -I
"""Minimal App Store Connect API client for scripts/testflight.sh.

    scripts/asc.py GET /v1/apps?filter[bundleId]=com.owenconti.cadence
    scripts/asc.py POST /v1/betaGroups '{"data": {...}}'
    scripts/asc.py signing   # prints KEYCHAIN, IDENTITY and PROFILE lines
    scripts/asc.py mac-profile   # prints the Mac's Developer ID profile path, if it has iCloud

`signing` makes sure there's an App Store distribution certificate (its key in
a keychain of its own, so codesign never prompts) and a current App Store
profile for com.owenconti.cadence, creating them through the API if needed.

Reads the API key that testflight.sh uses (~/.appstoreconnect/cadence.env and
private_keys/AuthKey_<id>.p8) and prints the JSON response. Signs the token
with openssl, so it needs nothing outside the standard library.
"""
import base64, datetime, json, os, plistlib, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

HOME = os.path.expanduser("~/.appstoreconnect")
# Cadence's own data (CloudStore.swift). Created in the Developer portal
# (Identifiers › iCloud Containers) and ticked on the App ID's iCloud
# capability; the API can do neither.
CLOUD_CONTAINER = "iCloud.com.owenconti.cadence"


def config():
    values = {}
    with open(os.path.join(HOME, "cadence.env")) as f:
        for line in f:
            if "=" in line:
                key, value = line.strip().split("=", 1)
                values[key] = value
    return values["ASC_KEY_ID"], values["ASC_ISSUER_ID"]


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der):
    """openssl's DER ECDSA signature to the JWT form: r and s, 32 bytes each."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        parts.append(der[i + 2:i + 2 + length].lstrip(b"\0").rjust(32, b"\0"))
        i += 2 + length
    return b"".join(parts)


def token():
    key_id, issuer = config()
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    payload = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}).encode())
    signing_input = header + b"." + payload
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.path.join(HOME, "private_keys", f"AuthKey_{key_id}.p8")],
        input=signing_input, capture_output=True, check=True,
    ).stdout
    return (signing_input + b"." + b64(der_to_raw(der))).decode()


def api(method, path, body=None):
    data = json.dumps(body).encode() if isinstance(body, dict) else body
    request = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token())
    if data:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path}: {error.code} {error.read().decode()}")
    return json.loads(text) if text else {}


BUNDLE_ID = os.environ.get("CADENCE_SIGN_BUNDLE", "com.owenconti.cadence")
PROFILE_NAME = "Cadence iOS App Store" if BUNDLE_ID == "com.owenconti.cadence" else "Cadence Watch App Store"
KEYCHAIN = os.path.join(HOME, "cadence-signing.keychain-db")
CERT_ID_FILE = os.path.join(HOME, "cadence-distribution-cert-id")
PROFILE_FILE = os.path.join(HOME, "Cadence_AppStore.mobileprovision" if BUNDLE_ID == "com.owenconti.cadence" else "Cadence_Watch_AppStore.mobileprovision")


def sh(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


def keychain_password():
    path = os.path.join(HOME, "cadence-keychain-password")
    if not os.path.exists(path):
        with open(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600), "w") as f:
            f.write(base64.urlsafe_b64encode(os.urandom(24)).decode())
    with open(path) as f:
        return f.read().strip()


def distribution_identity():
    # Not -v: the chain only validates while the keychain is in the search list.
    out = sh("security", "find-identity", "-p", "codesigning", KEYCHAIN).decode()
    for line in out.splitlines():
        if "Apple Distribution" in line:
            return line.split()[1]
    return None


def ensure_certificate(password):
    if not os.path.exists(KEYCHAIN):
        sh("security", "create-keychain", "-p", password, KEYCHAIN)
    sh("security", "unlock-keychain", "-p", password, KEYCHAIN)
    sh("security", "set-keychain-settings", KEYCHAIN)  # no auto-lock
    identity = distribution_identity()
    if identity and os.path.exists(CERT_ID_FILE):
        return identity, open(CERT_ID_FILE).read().strip()

    work = os.path.join(HOME, "cadence-cert-work")
    os.makedirs(work, mode=0o700, exist_ok=True)
    key, csr = os.path.join(work, "key.pem"), os.path.join(work, "csr.pem")
    sh("openssl", "genrsa", "-out", key, "2048")
    sh("openssl", "req", "-new", "-key", key, "-out", csr, "-subj", "/CN=Cadence TestFlight/O=Owen Conti/C=CA")
    csr_text = open(csr).read()
    created = api("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr_text}}})["data"]
    cer, pem, p12 = (os.path.join(work, n) for n in ("cert.cer", "cert.pem", "cert.p12"))
    with open(cer, "wb") as f:
        f.write(base64.b64decode(created["attributes"]["certificateContent"]))
    sh("openssl", "x509", "-inform", "DER", "-in", cer, "-out", pem)
    sh("openssl", "pkcs12", "-export", "-inkey", key, "-in", pem, "-out", p12, "-passout", "pass:" + password)
    # Any app may use the key while this keychain is unlocked (codesign's own
    # ACL entry doesn't match on macOS 27, and every mismatch is a password
    # prompt). testflight.sh unlocks it only to sign and locks it after.
    sh("security", "import", p12, "-k", KEYCHAIN, "-P", password, "-A")
    sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, KEYCHAIN)
    with open(CERT_ID_FILE, "w") as f:
        f.write(created["id"])
    for name in (key, csr, cer, pem, p12):
        os.remove(name)
    identity = distribution_identity()
    if not identity:
        sys.exit("the new distribution certificate didn't show up in the signing keychain")
    return identity, created["id"]


def ensure_profile(cert_id):
    profiles = api("GET", "/v1/profiles?filter%5Bname%5D=" + urllib.parse.quote(PROFILE_NAME) + "&include=certificates")
    for profile in profiles["data"]:
        certs = [c["id"] for c in profile["relationships"]["certificates"]["data"]]
        # A profile made before CarPlay Audio was enabled on the App ID lacks it.
        content = base64.b64decode(profile["attributes"]["profileContent"])
        carplay = b"com.apple.developer.carplay-audio" in content
        # Likewise one made before the iCloud container was assigned; until it
        # is, each upload remakes the profile (and ships without iCloud).
        cloud = CLOUD_CONTAINER.encode() in content
        if profile["attributes"]["profileState"] == "ACTIVE" and cert_id in certs and (BUNDLE_ID != "com.owenconti.cadence" or (carplay and cloud)):
            return profile["attributes"]["profileContent"]
        api("DELETE", "/v1/profiles/" + profile["id"])
    bundle = api("GET", "/v1/bundleIds?filter%5Bidentifier%5D=" + BUNDLE_ID)["data"]
    bundle = next((b for b in bundle if b["attributes"]["identifier"] == BUNDLE_ID), None)
    if bundle is None:
        sys.exit("Register explicit App ID " + BUNDLE_ID + " for team HBLWB8LVKC in Apple Developer Identifiers; no additional capabilities required for WatchConnectivity.")
    created = api("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
    return created["data"]["attributes"]["profileContent"]


def signing():
    password = keychain_password()
    identity, cert_id = ensure_certificate(password)
    with open(PROFILE_FILE, "wb") as f:
        f.write(base64.b64decode(ensure_profile(cert_id)))
    print("KEYCHAIN=" + KEYCHAIN)
    print("IDENTITY=" + identity)
    print("PROFILE=" + PROFILE_FILE)


MAC_PROFILE_NAME = "Cadence Mac Developer ID"
MAC_PROFILE_FILE = os.path.join(HOME, "Cadence_DeveloperID.provisionprofile")
MAC_PROFILE_STAMP = os.path.join(HOME, "cadence-mac-profile-checked")


def profile_usable(content):
    """Has the iCloud container and hasn't expired."""
    start, end = content.find(b"<?xml"), content.find(b"</plist>")
    if start < 0 or end < 0:
        return False
    plist = plistlib.loads(content[start:end + len(b"</plist>")])
    containers = plist.get("Entitlements", {}).get("com.apple.developer.icloud-container-identifiers", [])
    expires = plist.get("ExpirationDate")
    now = datetime.datetime.now(expires.tzinfo) if expires and expires.tzinfo else datetime.datetime.now()
    return CLOUD_CONTAINER in containers and (expires is None or expires > now + datetime.timedelta(days=1))


def mac_profile():
    """For scripts/bundle.sh: the Developer ID profile that lets the Mac app
    use iCloud, made through the API when missing. Prints its path, or nothing
    (the app is then signed without iCloud). Asks the API at most hourly, so
    builds stay fast while the container isn't set up yet."""
    if os.path.exists(MAC_PROFILE_FILE) and profile_usable(open(MAC_PROFILE_FILE, "rb").read()):
        print(MAC_PROFILE_FILE)
        return
    if os.path.exists(MAC_PROFILE_STAMP) and time.time() - os.path.getmtime(MAC_PROFILE_STAMP) < 3600:
        return
    open(MAC_PROFILE_STAMP, "w").close()
    certs = api("GET", "/v1/certificates?limit=200")["data"]
    cert = next((c for c in certs if c["attributes"]["certificateType"].startswith("DEVELOPER_ID_APPLICATION")), None)
    if cert is None:
        print("note: no Developer ID certificate in the developer account; building without iCloud", file=sys.stderr)
        return
    for profile in api("GET", "/v1/profiles?filter%5Bname%5D=" + urllib.parse.quote(MAC_PROFILE_NAME))["data"]:
        content = base64.b64decode(profile["attributes"]["profileContent"])
        if profile["attributes"]["profileState"] == "ACTIVE" and profile_usable(content):
            with open(MAC_PROFILE_FILE, "wb") as f:
                f.write(content)
            print(MAC_PROFILE_FILE)
            return
        api("DELETE", "/v1/profiles/" + profile["id"])
    bundle = api("GET", "/v1/bundleIds?filter%5Bidentifier%5D=com.owenconti.cadence")["data"]
    bundle = next(b for b in bundle if b["attributes"]["identifier"] == "com.owenconti.cadence")
    created = api("POST", "/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": MAC_PROFILE_NAME, "profileType": "MAC_APP_DIRECT"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})
    content = base64.b64decode(created["data"]["attributes"]["profileContent"])
    if not profile_usable(content):
        print(f"note: iCloud is off until {CLOUD_CONTAINER} is created and ticked on the App ID's iCloud capability (see README)", file=sys.stderr)
        return
    with open(MAC_PROFILE_FILE, "wb") as f:
        f.write(content)
    print(MAC_PROFILE_FILE)


def main():
    if sys.argv[1] == "signing":
        return signing()
    if sys.argv[1] == "mac-profile":
        return mac_profile()
    body = sys.argv[3].encode() if len(sys.argv) > 3 else None
    print(json.dumps(api(sys.argv[1], sys.argv[2], body)))


if __name__ == "__main__":
    main()
