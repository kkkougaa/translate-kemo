"""App Store Connect 상태 확인 — TestFlight 잡이 아카이브 전에 부른다.

- 팀에 등록된 번들 ID 를 주석으로 찍는다 (App Store Connect '신규 앱' 목록에 뭐가 뜰지 보려고)
- 앱 본체 번들 ID 가 없으면 API 로 등록한다
- 그 번들 ID 로 만든 앱이 App Store Connect 에 없으면 경고를 남긴다 (없으면 업로드가 실패한다)

어떤 오류도 잡을 실패로 만들지 않는다.
사용: asc_check.py <키 파일> <키 ID> <발급자 ID> <번들 ID> <이름>
"""
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"


def main():
    key_path, kid, iss, bundle, name = sys.argv[1:6]
    now = int(time.time())
    token = jwt.encode({"iss": iss, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                       open(key_path).read(), algorithm="ES256", headers={"kid": kid, "typ": "JWT"})

    def call(path, body=None):
        req = urllib.request.Request(API + path, method="POST" if body else "GET",
                                     data=json.dumps(body).encode() if body else None,
                                     headers={"Authorization": "Bearer " + token,
                                              "Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(req, timeout=30))

    ids = call("/v1/bundleIds?limit=200&fields[bundleIds]=identifier,name,platform")["data"]
    for b in ids:
        a = b["attributes"]
        print(f"::notice::번들 ID {a['identifier']} ({a['name']}, {a['platform']})")

    if not any(b["attributes"]["identifier"] == bundle for b in ids):
        call("/v1/bundleIds", {"data": {"type": "bundleIds",
                                        "attributes": {"identifier": bundle, "name": name, "platform": "IOS"}}})
        print(f"::notice::{bundle} 가 없어서 등록했다")

    q = urllib.parse.quote(bundle)
    apps = call(f"/v1/apps?filter[bundleId]={q}&fields[apps]=name,bundleId")["data"]
    if apps:
        print(f"::notice::App Store Connect 앱 있음: {apps[0]['attributes']['name']}")
    else:
        print(f"::warning::App Store Connect 에 {bundle} 앱이 없다. 앱 → 신규 앱에서 만들어야 업로드된다")


try:
    main()
except urllib.error.HTTPError as e:
    print(f"::warning::App Store Connect 확인 실패 ({e.code}): {e.read().decode()[:300]}")
except Exception as e:  # noqa: BLE001 — 확인용이라 무엇이든 경고로만
    print(f"::warning::App Store Connect 확인 실패: {e}")
