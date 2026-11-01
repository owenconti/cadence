#!/usr/bin/env python3 -I
"""Minimal App Store Connect API client for scripts/testflight.sh.

    scripts/asc.py GET /v1/apps?filter[bundleId]=com.owenconti.cadence
    scripts/asc.py POST /v1/betaGroups '{"data": {...}}'

Reads the API key that testflight.sh uses (~/.appstoreconnect/cadence.env and
private_keys/AuthKey_<id>.p8) and prints the JSON response. Signs the token
with openssl, so it needs nothing outside the standard library.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

HOME = os.path.expanduser("~/.appstoreconnect")


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


def main():
    method, path = sys.argv[1], sys.argv[2]
    body = sys.argv[3].encode() if len(sys.argv) > 3 else None
    request = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, data=body, method=method)
    request.add_header("Authorization", "Bearer " + token())
    if body:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        print(error.read().decode(), file=sys.stderr)
        sys.exit(1)
    print(text or "{}")


if __name__ == "__main__":
    main()
