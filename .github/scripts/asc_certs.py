"""CI 가 만든 개발용 인증서 치우기.

자동 서명은 러너마다 개발용 인증서를 새로 만들고, 개인 키는 러너와 함께 사라진다.
그대로 두면 팀 인증서 한도가 차서 다음 빌드가 'maximum number of certificates' 로 떨어진다.
이름에 'Created via API' 가 붙은 개발용 인증서(= CI 가 만든 것)만 지운다. 사람이 만든 인증서와 배포 인증서는 건드리지 않는다.

사용:
  asc_certs.py <키 파일> <키 ID> <발급자 ID> stale            20분보다 오래된 CI 인증서를 지운다 (다른 실행이 쓰는 중인 건 남김)
  asc_certs.py <키 파일> <키 ID> <발급자 ID> revoke <일련번호>…  이번 실행이 만든 인증서를 지운다
어떤 오류도 잡을 실패로 만들지 않는다.
"""
import datetime as dt
import json
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
MARK = "Created via API"


def main():
    key_path, kid, iss, mode = sys.argv[1:5]
    serials = {s.upper().lstrip("0") for s in sys.argv[5:]}
    now = int(time.time())
    token = jwt.encode({"iss": iss, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                       open(key_path).read(), algorithm="ES256", headers={"kid": kid, "typ": "JWT"})

    def call(path, method="GET"):
        req = urllib.request.Request(API + path, method=method, headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
        return json.loads(body) if body else None

    certs = call("/v1/certificates?limit=200&fields[certificates]=name,displayName,certificateType,serialNumber,expirationDate")["data"]
    # 인증서는 1년짜리라 만료일에서 1년을 빼면 만든 때다
    year = dt.timedelta(days=365)
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=20)
    # 로그는 로그인해야 보여서, 어떤 인증서가 있는지 주석 한 줄로 요약한다
    kinds = {}
    for c in certs:
        a = c["attributes"]
        k = f"{a['certificateType']} {a['name'] or a['displayName']}"
        kinds[k] = kinds.get(k, 0) + 1
    print("::notice::인증서 " + " / ".join(f"{k} ×{n}" for k, n in sorted(kinds.items())))
    gone = 0
    for c in certs:
        a = c["attributes"]
        if "DEVELOPMENT" not in a["certificateType"] or MARK not in (a["name"] or "") + (a["displayName"] or ""):
            continue
        made = dt.datetime.fromisoformat(a["expirationDate"].replace("Z", "+00:00")) - year
        if mode == "stale" and made > cutoff:
            continue
        if mode == "revoke" and a["serialNumber"].upper().lstrip("0") not in serials:
            continue
        call(f"/v1/certificates/{c['id']}", method="DELETE")
        gone += 1
    print(f"::notice::CI 가 만든 개발용 인증서 {gone}개 정리 (전체 인증서 {len(certs)}개)")


try:
    main()
except urllib.error.HTTPError as e:
    print(f"::warning::인증서 정리 실패 ({e.code}): {e.read().decode()[:300]}")
except Exception as e:  # noqa: BLE001 — 정리용이라 무엇이든 경고로만
    print(f"::warning::인증서 정리 실패: {e}")
