"""TestFlight 외부 테스트 심사 제출 — 처리(VALID)가 끝난 빌드를 외부 그룹에 넣고 베타 심사에 낸다.

순서
  1) 빌드 찾기 (빌드 번호) — 처리 완료(VALID)여야 한다
  2) 수출 규정(암호화) 답이 비어 있으면 '안 씀'으로 채운다 (Info.plist 에도 넣어 뒀다)
  3) 베타 심사 연락처 확인 — 비어 있으면 BETA_CONTACT_* 값으로 채운다, 그것도 없으면 실패
  4) 베타 앱 설명(테스트 정보) 확인 — 없으면 한국어로 만든다
  5) 이번 빌드의 '테스트할 내용' 적기
  6) 외부 테스트 그룹에 빌드 넣기 — 그룹이 없으면 만든다
  7) 베타 앱 심사 제출 (이미 냈거나 승인됐으면 건너뛴다)

사용: asc_beta_review.py <키 파일> <키 ID> <발급자 ID> <번들 ID> <빌드 번호> <그룹 이름> <테스트할 내용>
환경 변수 (선택, 연락처가 App Store Connect 에 아직 없을 때만 쓴다)
  BETA_CONTACT_FIRST · BETA_CONTACT_LAST · BETA_CONTACT_PHONE · BETA_CONTACT_EMAIL
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
PRIVACY_URL = "https://kkkougaa.github.io/kouga-translate/privacy.html"
DESCRIPTION = ("한국어 ↔ 일본어·영어·중국어 번역기입니다. 글을 넣거나 다른 앱에서 글을 골라 번역하고, "
               "대화 모드·화면 소리 번역·사진 번역을 씁니다. Gemini API 키는 이용자가 직접 넣습니다.")


class Fail(Exception):
    pass


def main():
    key_path, kid, iss, bundle, number, group_name, whats_new = sys.argv[1:8]
    key = open(key_path).read()

    def call(path, method="GET", body=None):
        now = int(time.time())
        token = jwt.encode({"iss": iss, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                           key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})
        req = urllib.request.Request(API + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": "Bearer " + token,
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
        return json.loads(raw) if raw else {}

    # 1) 앱 · 빌드
    apps = call(f"/v1/apps?filter[bundleId]={urllib.parse.quote(bundle)}")["data"]
    if not apps:
        raise Fail(f"App Store Connect 에 {bundle} 앱이 없다")
    app = apps[0]["id"]

    build = None
    for _ in range(20):  # 처리 지켜보기가 먼저 끝났어도 목록 반영이 늦을 수 있어 조금 더 기다린다
        r = call(f"/v1/builds?filter[app]={app}&filter[version]={urllib.parse.quote(number)}"
                 "&fields[builds]=version,processingState,usesNonExemptEncryption,expired&limit=1")["data"]
        if r and r[0]["attributes"]["processingState"] == "VALID":
            build = r[0]
            break
        state = r[0]["attributes"]["processingState"] if r else "목록에 없음"
        if state in ("INVALID", "FAILED"):
            raise Fail(f"빌드 {number} 처리 실패({state}) — 심사에 낼 수 없다")
        print(f"빌드 {number}: {state} — 기다리는 중", flush=True)
        time.sleep(30)
    if not build:
        raise Fail(f"빌드 {number} 처리가 아직 안 끝났다. 끝난 뒤 다시 실행해 줘")
    bid = build["id"]
    print(f"빌드 {number} ({bid}) 처리 완료")

    # 2) 수출 규정
    if build["attributes"].get("usesNonExemptEncryption") is None:
        call(f"/v1/builds/{bid}", "PATCH", {"data": {"type": "builds", "id": bid,
                                                       "attributes": {"usesNonExemptEncryption": False}}})
        print("수출 규정: 암호화 안 씀으로 답했다")

    # 3) 베타 심사 연락처
    detail = call(f"/v1/apps/{app}/betaAppReviewDetail")["data"]
    have = detail["attributes"]
    env = {"contactFirstName": os.environ.get("BETA_CONTACT_FIRST", "").strip(),
           "contactLastName": os.environ.get("BETA_CONTACT_LAST", "").strip(),
           "contactPhone": os.environ.get("BETA_CONTACT_PHONE", "").strip(),
           "contactEmail": os.environ.get("BETA_CONTACT_EMAIL", "").strip()}
    fill = {k: v for k, v in env.items() if not have.get(k) and v}
    if fill:
        if have.get("demoAccountRequired") is None:
            fill["demoAccountRequired"] = False
        call(f"/v1/betaAppReviewDetails/{detail['id']}", "PATCH",
             {"data": {"type": "betaAppReviewDetails", "id": detail["id"], "attributes": fill}})
        have.update(fill)
        print("베타 심사 연락처를 채웠다: " + ", ".join(fill))
    missing = [k for k in env if not have.get(k)]
    if missing:
        raise Fail("베타 심사 연락처가 비어 있다 (" + ", ".join(missing) + "). "
                   "App Store Connect → TestFlight → 테스트 정보에서 한 번 채우거나, "
                   "저장소 Secrets 에 BETA_CONTACT_FIRST · BETA_CONTACT_LAST · BETA_CONTACT_PHONE · BETA_CONTACT_EMAIL 을 넣어 줘")

    # 4) 베타 앱 설명
    locs = call(f"/v1/apps/{app}/betaAppLocalizations")["data"]
    if not any(l["attributes"].get("description") and l["attributes"].get("feedbackEmail") for l in locs):
        ko = next((l for l in locs if l["attributes"]["locale"] == "ko"), None)
        attrs = {"description": DESCRIPTION, "feedbackEmail": have["contactEmail"], "privacyPolicyUrl": PRIVACY_URL}
        if ko:
            attrs = {k: v for k, v in attrs.items() if not ko["attributes"].get(k)}
            call(f"/v1/betaAppLocalizations/{ko['id']}", "PATCH",
                 {"data": {"type": "betaAppLocalizations", "id": ko["id"], "attributes": attrs}})
        else:
            call("/v1/betaAppLocalizations", "POST",
                 {"data": {"type": "betaAppLocalizations", "attributes": {"locale": "ko", **attrs},
                           "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})
        print("베타 앱 설명(한국어)을 채웠다")

    # 5) 테스트할 내용
    if whats_new.strip():
        text = whats_new.strip()[:4000]
        bl = call(f"/v1/builds/{bid}/betaBuildLocalizations")["data"]
        ko = next((l for l in bl if l["attributes"]["locale"] == "ko"), None)
        if ko:
            call(f"/v1/betaBuildLocalizations/{ko['id']}", "PATCH",
                 {"data": {"type": "betaBuildLocalizations", "id": ko["id"], "attributes": {"whatsNew": text}}})
        else:
            call("/v1/betaBuildLocalizations", "POST",
                 {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "ko", "whatsNew": text},
                           "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
        print("테스트할 내용: " + text.splitlines()[0])

    # 6) 외부 그룹
    groups = call(f"/v1/apps/{app}/betaGroups?limit=200&fields[betaGroups]=name,isInternalGroup")["data"]
    ext = [g for g in groups if not g["attributes"]["isInternalGroup"]]
    group = next((g for g in ext if g["attributes"]["name"] == group_name), None)
    if not group:
        group = call("/v1/betaGroups", "POST",
                     {"data": {"type": "betaGroups", "attributes": {"name": group_name},
                               "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]
        print(f"외부 테스트 그룹 '{group_name}' 을 만들었다")
    call(f"/v1/betaGroups/{group['id']}/relationships/builds", "POST",
         {"data": [{"type": "builds", "id": bid}]})
    print(f"빌드 {number} 를 외부 그룹 '{group_name}' 에 넣었다")

    # 7) 심사 제출
    state = call(f"/v1/builds/{bid}/buildBetaDetail")["data"]["attributes"].get("externalBuildState")
    if state in ("WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_APPROVED", "IN_BETA_TESTING"):
        print(f"::notice::빌드 {number} 는 이미 {state} — 제출을 건너뛴다")
        return
    try:
        call("/v1/betaAppReviewSubmissions", "POST",
             {"data": {"type": "betaAppReviewSubmissions",
                       "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
    except urllib.error.HTTPError as e:
        if e.code != 409:
            raise
        print(f"제출 응답 409: {e.read().decode()[:300]}")
    state = call(f"/v1/builds/{bid}/buildBetaDetail")["data"]["attributes"].get("externalBuildState")
    print(f"::notice::빌드 {number} 외부 테스트 심사 제출 — 지금 상태 {state}. 승인되면 '{group_name}' 그룹 테스터에게 간다")


try:
    main()
except Fail as e:
    print(f"::error::{e}")
    sys.exit(1)
except urllib.error.HTTPError as e:
    print(f"::error::App Store Connect 요청 실패 ({e.code} {e.url}): {e.read().decode()[:500]}")
    sys.exit(1)
