"""TestFlight 처리 지켜보기 — 업로드 뒤에 부른다.

App Store Connect 에 올라간 최근 빌드와 처리 상태를 주석으로 찍고,
방금 올린 빌드 번호가 처리 완료(VALID)·실패(INVALID/FAILED)가 될 때까지 기다린다.
화면엔 처리 중일 때 아무것도 안 보여서 여기서 대신 본다. 어떤 결과도 잡을 실패로 만들지 않는다.
사용: asc_builds.py <키 파일> <키 ID> <발급자 ID> <번들 ID> <빌드 번호> [기다릴 분]
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
    key_path, kid, iss, bundle, number = sys.argv[1:6]
    wait_min = int(sys.argv[6]) if len(sys.argv) > 6 else 30
    key = open(key_path).read()

    def call(path):
        now = int(time.time())
        token = jwt.encode({"iss": iss, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                           key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})
        req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token})
        return json.load(urllib.request.urlopen(req, timeout=30))

    apps = call(f"/v1/apps?filter[bundleId]={urllib.parse.quote(bundle)}")["data"]
    if not apps:
        print(f"::warning::App Store Connect 에 {bundle} 앱이 없다")
        return
    app = apps[0]["id"]

    def builds():
        r = call(f"/v1/builds?filter[app]={app}&sort=-uploadedDate&limit=10"
                 "&fields[builds]=version,processingState,uploadedDate,expired")
        return [b["attributes"] for b in r["data"]]

    for b in builds():
        print(f"::notice::올라간 빌드 {b['version']} — {b['processingState']} ({b['uploadedDate']})")

    deadline = time.time() + wait_min * 60
    last = None
    while time.time() < deadline:
        mine = next((b for b in builds() if b["version"] == number), None)
        state = mine["processingState"] if mine else "NOT_YET"
        if state != last:
            print(f"빌드 {number}: {state}", flush=True)
            last = state
        if state == "VALID":
            print(f"::notice::빌드 {number} 처리 완료 — TestFlight 에서 테스터에게 줄 수 있다")
            return
        if state in ("INVALID", "FAILED"):
            print(f"::error::빌드 {number} 처리 실패({state}) — 이유는 계정 주인 메일(App Store Connect)로 온다")
            return
        time.sleep(30)
    if last == "NOT_YET":
        print(f"::warning::{wait_min}분 동안 빌드 {number} 가 목록에 안 나타났다 — 애플이 처리 전에 거절했을 수 있다. 계정 주인 메일 확인")
    else:
        print(f"::warning::{wait_min}분 안에 처리가 안 끝났다 (마지막 상태 {last}). 조금 더 기다려 보면 된다")


try:
    main()
except urllib.error.HTTPError as e:
    print(f"::warning::App Store Connect 조회 실패 ({e.code}): {e.read().decode()[:300]}")
except Exception as e:  # noqa: BLE001 — 지켜보기용이라 무엇이든 경고로만
    print(f"::warning::App Store Connect 조회 실패: {e}")
