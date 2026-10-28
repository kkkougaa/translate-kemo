# translate-kemo

한국어 ↔ 일본어·영어·중국어 번역기 iOS 앱. 일본 친구와 LINE·X 로 대화할 때 쓰려고 만들었다.
웹 판([kouga-translate](https://github.com/kkkougaa/kouga-translate) 의 `translator.html`)을 SwiftUI 로 옮긴 것으로, 프롬프트와 뒷정리 규칙은 웹 판과 같게 유지한다.
원래 지하철 앱 [kemometro](https://github.com/kkkougaa/kemometro) 안에 같이 있다가 따로 떨어져 나왔다.

- 번들 ID `com.kouga.kemotranslate`, 앱 그룹 `group.com.kouga.kemotranslate`
- Gemini(번역·독음·사전·TTS·사진), Soniox(대화 모드·화면 소리 번역·말로 입력) — 키는 이용자가 직접 넣는다

## 빌드 · 배포

맥 없이 GitHub Actions 의 macOS 러너가 빌드한다.

- `main` 에 합치면 정식 서명해서 **TestFlight** 에 올린다. 저장소 Secrets 가 필요하다:
  `ASC_KEY_ID` · `ASC_ISSUER_ID` · `ASC_KEY_P8`(App Store Connect 팀 API 키 .p8 내용 전체) · `APPLE_TEAM_ID`.
  없으면 무서명 ipa 만 아티팩트로 남긴다.
- 그 밖의 브랜치는 컴파일 확인만 한다.

## 구조

```
project.yml                XcodeGen 정의 (앱 + 확장 셋). .xcodeproj 는 CI 에서 생성
App/
  TranslateKemoApp.swift   시작점 — TranslatorView 하나
  Translator/              화면·번역 흐름 전부
    TLText · TLPrompt      뒷정리·섞임 검사·용어집·프롬프트 (웹 판과 같은 규칙)
    Gemini                 스트리밍(SSE)·우선 처리·재시도·키 확인
    TLStore                설정·기록 (UserDefaults 'tl.' + 웹 판 localStorage 키 이름)
    TranslatorModel / View 번역 화면, TLTabBar 하단 글래스 바, TLPages 서랍·기록·용어집·설정
    TLScreen*              화면 소리 번역 (방송 확장 → Soniox → PIP 자막)
    TLTalk · TLStudy · TLWords · TLBackup   대화 모드 · 공부 · 표현 노트 · 백업
  Assets.xcassets          앱 아이콘, PIP 자막·카드에 쓰는 logo
  PrivacyInfo.xcprivacy    개인정보 매니페스트
Shared/                    글래스·햅틱 도우미 (확장도 같이 쓴다)
ShareExtension/            공유 시트 "translate-kemo" 카드
TranslateExtension/        기본 번역 앱 확장 (iOS 18.4+), 카드는 ShareExtension 것을 쓴다
BroadcastExtension/        화면 기록 확장 — 다른 앱 소리를 16kHz 모노로 127.0.0.1:48231 에 넘긴다
```

개인정보 처리방침: https://kkkougaa.github.io/kouga-translate/privacy.html
