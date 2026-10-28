import PhotosUI
import SwiftUI
import UIKit

// 번역기 메인 화면. translator.html 의 배치를 그대로 옮겼다:
// 헤더 → 언어 바 → 입력 카드 → 번역 옵션 → 결과 → 피드백.
// 아래 탭 바(iOS 26 에선 리퀴드 글래스): 번역 · PIP 번역 · 대화 모드 · 메뉴(오른쪽 서랍, 설정은 그 안에)

enum TLRoute: Hashable { case history, glossary, settings, tones, chips, study, words, talk, screen }
enum TLTab: Hashable { case home, screen, talk, settings }

struct TranslatorView: View {
    @StateObject private var m = TranslatorModel()
    @ObservedObject private var store = TLStore.shared
    @State private var path: [TLRoute] = []
    @State private var setPath: [TLRoute] = []
    @State private var tab: TLTab = .home
    /// 아래로 스크롤하면 탭 바를 접고 오른쪽 아래에 쓰기 버튼을 띄운다
    @State private var barCollapsed = false
    /// 한 번 연 탭만 만들어 두고 계속 살려 둔다 (전환해도 입력·스크롤이 그대로)
    @State private var visited: Set<TLTab> = [.home]
    /// 쓰기 버튼 → 번역 화면 맨 위로
    @State private var scrollTopTick = 0
    /// 키보드가 떠 있으면 하단 바가 그 뒤로 숨으니 바 자리를 비우지 않는다
    @State private var keyboardUp = false
    @State private var drawerOpen = false
    @State private var optOpen = false
    @State private var fbText = ""
    @FocusState private var focus: Field?
    @AppStorage("tl.result_size") private var rsize = TLResultSize.md.rawValue
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pillNS
    @ObservedObject private var audio = TLAudio.shared
    @ObservedObject private var dictation = TLDictation.shared
    @ObservedObject private var deviceDictation = TLDeviceDictation.shared
    @State private var dictTarget: TLDictTarget?
    @State private var showBig = false
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?

    enum Field { case input, extra, charPrompt, feedback }

    private var resultFont: CGFloat { (TLResultSize(rawValue: rsize) ?? .md).points }
    private var canTranslate: Bool { !m.input.trimmed.isEmpty || m.attached != nil }
    /// 말로 입력 엔진 — 설정에서 고른다. Soniox 를 골랐는데 키가 없으면 기기 안으로
    private var useDevice: Bool { store.dictationEngine != "soniox" || !dictation.available }

    var body: some View {
        // 시스템 탭 바 대신 직접 그린 글래스 바(TLTabBar). 화면은 겹쳐 두고 보이는 것만 바꾼다.
        ZStack {
            tabPage(.home) { homeStack }
            tabPage(.screen) { NavigationStack { TLScreenPage().tlBarSpace() } }
            tabPage(.talk) { NavigationStack { TLTalkPage(otherLang: m.tgtLang).tlBarSpace() } }
            tabPage(.settings) {
                NavigationStack(path: $setPath) {
                    TLSettingsPage(tgtLang: m.tgtLang)
                        .tlBarSpace()
                        .navigationDestination(for: TLRoute.self) { r in routeView(r) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            // 평소엔 키보드 뒤에 숨고, 입력칸을 누르면 번역 버튼이 되어 키보드 위로 올라온다
            TLTabBar(tab: $tab, mode: barMode, busy: m.busy, canTranslate: canTranslate,
                     onWrite: write, onTranslate: { m.translateOrCancel() },
                     onMenu: { focus = nil; drawerOpen = true })
                .ignoresSafeArea(barMode == .translate ? [] : .keyboard)
                .animation(.spring(duration: 0.45, bounce: 0.22), value: barMode)
        }
        .onChange(of: tab) { _, t in visited.insert(t) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .overlay {
            TLDrawer(open: $drawerOpen) { route in
                if route == .settings { tab = .settings } else { tab = .home; path = [route] }
            }
        }
        .tint(.tlAccent)
        .task { TLShare.publish() }
    }

    /// 탭 화면 하나 — 처음 열 때 만들고, 아래 바 높이만큼 내용을 띄운다
    @ViewBuilder
    private func tabPage<V: View>(_ t: TLTab, @ViewBuilder _ content: () -> V) -> some View {
        if visited.contains(t) {
            content()
                .environment(\.tlBarSpace, keyboardUp || focus != nil ? 0 : TLTabBar.height + 8)
                .opacity(tab == t ? 1 : 0)
                .allowsHitTesting(tab == t)
                .accessibilityHidden(tab != t)
        }
    }

    /// 하단 바 모양 — 번역 화면에서만 접히거나 번역 버튼이 된다
    private var barMode: TLBarMode {
        guard tab == .home else { return .full }
        if focus == .input { return .translate }
        return barCollapsed ? .write : .full
    }

    /// 쓰기 버튼 — 번역 화면 맨 위로 올라가 입력칸에 키보드를 연다
    private func write() {
        TLHaptic.select()
        tab = .home
        scrollTopTick += 1
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { barCollapsed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = .input }
    }

    /// 들어가는 화면에도 하단 바 자리를 비운다
    private func routeView(_ r: TLRoute) -> some View {
        routeContent(r).tlBarSpace()
    }

    @ViewBuilder
    private func routeContent(_ r: TLRoute) -> some View {
        switch r {
        case .history: TLHistoryPage { h in m.loadHistory(h); path = []; tab = .home }
        case .glossary: TLGlossaryPage(lang: m.tgtLang)
        case .settings: TLSettingsPage(tgtLang: m.tgtLang)
        case .tones: TLTonesPage()
        case .chips: TLChipsPage(outLang: m.outLang)
        case .study: TLStudyPage(tgtLang: m.tgtLang)
        case .words: TLWordsPage()
        case .talk: TLTalkPage(otherLang: m.tgtLang)
        case .screen: TLScreenPage()
        }
    }

    private var homeStack: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                Color.tlBg.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            header.id("top")
                            langBar
                            inputCard
                            optionsCard
                            resultCard
                            if m.succeeded { feedbackCard.transition(.opacity.combined(with: .move(edge: .bottom))) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 30)
                        .animation(.snappy(duration: 0.28), value: m.succeeded)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TLScrollOffsetKey.self, value: g.frame(in: .named("homeScroll")).minY)
                        })
                    }
                    .coordinateSpace(name: "homeScroll")
                    .scrollDismissesKeyboard(.interactively)
                    .onPreferenceChange(TLScrollOffsetKey.self) { y in setCollapsed(y < -90) }
                    .modifier(TLScrollWatch { down in setCollapsed(down > 90) })
                    .onChange(of: scrollTopTick) { _, _ in
                        withAnimation(.spring(duration: 0.45, bounce: 0.12)) { proxy.scrollTo("top", anchor: .top) }
                    }
                }

                if let t = m.toast {
                    Text(t)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .liquidGlass()
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

            }
            .toolbar(.hidden, for: .navigationBar)
            .tlBarSpace()
            .sheet(item: $dictTarget) { t in TLDictSheet(m: m, target: t) }
            .fullScreenCover(isPresented: $showBig) {
                TLBigView(text: TLText.cleanForCopy(m.result),
                          sub: m.srcLang == "ko" ? TLText.cleanForCopy(m.input) : "")
            }
            .fullScreenCover(isPresented: $showCamera) {
                TLCameraPicker { m.attach($0) }.ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: dictation.error) { _, e in if let e { m.show(e) } }
            .onChange(of: deviceDictation.error) { _, e in if let e { m.show(e) } }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let im = UIImage(data: data) { m.attach(im) }
                    photoItem = nil
                }
            }
            .navigationDestination(for: TLRoute.self) { r in routeView(r) }
        }
    }

    /// 조금 내려가면 바를 접고, 거의 맨 위로 돌아오면 편다. 글래스가 녹아드는 애니메이션은 바가 맡는다.
    private func setCollapsed(_ c: Bool) {
        guard c != barCollapsed else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.22)) { barCollapsed = c }
    }

    // MARK: 헤더

    private var header: some View {
        HStack(spacing: 8) {
            Image("logo")
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            Text("번역기")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.7)
                .padding(.leading, 2)
            Spacer()
            TLCircleButton(symbol: "clock.arrow.circlepath", label: "번역 기록") { path = [.history] }
        }
        .padding(.top, 2)
    }

    // MARK: 언어 바

    private var langBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button { withAnimation(.spring(duration: 0.32, bounce: 0.15)) { m.pickKorean() } } label: {
                    langLabel("한국어", active: m.srcLang == "ko")
                }
                .buttonStyle(.plain)
                .tapHaptic()

                Menu {
                    ForEach(TLLang.order, id: \.self) { l in
                        Button {
                            withAnimation(.spring(duration: 0.32, bounce: 0.15)) { m.pickTarget(l) }
                        } label: {
                            if l == m.tgtLang { Label(TLLang.cfg(l).label, systemImage: "checkmark") }
                            else { Text(TLLang.cfg(l).label) }
                        }
                    }
                } label: {
                    langLabel(TLLang.cfg(m.tgtLang).label, active: m.srcLang != "ko", chevron: true)
                }
                .buttonStyle(.plain)
            }
            .padding(3)
            .frame(height: 48)
            .liquidGlassCard(cornerRadius: 14)

            TLCircleButton(symbol: "arrow.left.arrow.right", size: 38, label: "방향 바꾸기") {
                withAnimation(.spring(duration: 0.32, bounce: 0.15)) { m.swap() }
            }
        }
    }

    private func langLabel(_ text: String, active: Bool, chevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(active ? Color.primary : Color.tlText2)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.tlText3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.tlFill)
                    .matchedGeometryEffect(id: "langPill", in: pillNS)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: 입력

    private var inputCard: some View {
        VStack(spacing: 0) {
            if let img = m.attached {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button { m.removeAttachment() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("사진 빼기")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            TextField(m.placeholder, text: $m.input, axis: .vertical)
                .font(.system(size: 17))
                .lineSpacing(3)
                .lineLimit(4...14)
                .focused($focus, equals: .input)
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 12)
                .frame(minHeight: 124, alignment: .topLeading)

            Divider().padding(.horizontal, 10)

            HStack(spacing: 2) {
                toolButton("doc.on.clipboard", "붙여넣기") { m.paste() }
                toolButton("xmark", "지우기") { m.clearInput(); focus = .input }
                // 버튼 바로 위에 펼쳐지는 메뉴
                Menu {
                    Button { focus = nil; showCamera = true } label: { Label("사진 찍기", systemImage: "camera") }
                    Button { focus = nil; showPhotos = true } label: { Label("앨범에서 선택", systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(m.attached != nil ? Color.tlAccent : Color.tlText2)
                        .frame(minWidth: 36, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("사진")
                if useDevice || dictation.available {
                    let on = useDevice ? deviceDictation.active : dictation.active
                    Button {
                        let lang = m.srcLang == "ko" ? "ko" : m.tgtLang
                        if useDevice {
                            deviceDictation.toggle(lang: lang, glossaryLang: m.tgtLang, base: m.input,
                                                   onText: { m.input = $0 }, onDone: nil)
                        } else {
                            dictation.toggle(lang: lang, glossaryLang: m.tgtLang, base: m.input,
                                             onText: { m.input = $0 }, onDone: nil)
                        }
                    } label: {
                        Image(systemName: on ? "mic.fill" : "mic")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(on ? Color.tlAccent : Color.tlText2)
                            .frame(minWidth: 36, minHeight: 36)
                            .contentShape(Rectangle())
                            .symbolEffect(.pulse, isActive: on)
                    }
                    .buttonStyle(.plain)
                    .tapHaptic()
                    .accessibilityLabel("말로 입력")
                }
                Spacer()
                Text("\(m.input.count) / 2000")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.tlText3)
                    .padding(.trailing, 6)
            }
            .frame(height: 44)
            .padding(.horizontal, 10)

            HStack(spacing: 8) {
                if let side = m.sideAction {
                    Button { m.runSideAction() } label: {
                        Text(side == .image ? "이미지" : "문법")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.tlText2)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .tapHaptic()
                    .disabled(m.busy || (side != .image && m.input.trimmed.isEmpty))
                }
                translateButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .tlCard()
    }

    private func toolButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.tlText2)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tapHaptic()
        .accessibilityLabel(label)
    }

    private var translateButton: some View {
        Button { m.translateOrCancel() } label: {
            HStack(spacing: 8) {
                if m.busy {
                    ProgressView().tint(Color.tlOnAccent).controlSize(.small)
                    Text("취소")
                } else {
                    Text("번역")
                    Image(systemName: "play.fill").font(.system(size: 11)).opacity(0.7)
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(store.buttonTint.isEmpty && store.buttonStrength >= 1 ? Color.tlOnAccent
                             : TLPalette.ink(on: store.buttonTint, strength: store.buttonStrength, dark: colorScheme == .dark))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
            .tlAccentGlass(cornerRadius: 12, color: TLPalette.buttonColor, clear: store.glassClear)
        }
        .buttonStyle(.plain)
        .tapHaptic()
        .opacity(!m.busy && !canTranslate ? 0.5 : 1)
        .disabled(!m.busy && !canTranslate)
    }

    // MARK: 번역 옵션

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !m.toKO else { return }
                withAnimation(.snappy(duration: 0.28)) { optOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text("번역 옵션").font(.system(size: 16)).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if m.toKO {
                        Text("역방향 번역 시 비활성").font(.system(size: 13)).foregroundStyle(Color.tlText3)
                    } else {
                        Text(m.optionsSummary)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.tlText2)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.tlText3)
                        .rotationEffect(.degrees(optOpen && !m.toKO ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if optOpen && !m.toKO {
                optionsBody
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .tlCard()
        .opacity(m.toKO ? 0.6 : 1)
        .clipped()
    }

    private var optionsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            optLabel("말투")
            TLFlow(spacing: 7) {
                ForEach(store.tones) { t in toneChip(t) }
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        m.extraOn.toggle()
                        if !m.extraOn { m.extraText = "" }
                    }
                    if m.extraOn { focus = .extra }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(m.extraOn ? Color.tlOnAccent : Color.tlText2)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(m.extraOn ? Color.tlAccent : Color.tlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .tapHaptic()
                .accessibilityLabel("추가 옵션")
            }

            if m.extraOn {
                optLabel("추가 옵션").padding(.top, 14)
                fieldBox("예) 번역 결과에 후리가나(フリガナ)를 같이 달아줘 / 경어는 쓰지 말고 반말로만 해줘",
                         text: $m.extraText, field: .extra)
            }
            if m.tone == "character" {
                optLabel("캐릭터 프롬프트").padding(.top, 14)
                fieldBox("예: 고양이 캐릭터, 어미에 ~냥 붙임, 귀엽고 장난스러운 말투",
                         text: $store.charPrompt, field: .charPrompt)
            }

            toggleRow("원문 충실 번역",
                      m.strict ? "on — 원문 그대로 충실하게 번역" : "off — 내용을 정리·보완하며 번역",
                      isOn: $m.strict)
            toggleRow("Thinking 모드",
                      store.thinking ? "on — 느리지만 정확하게" : "off — 빠른 번역",
                      isOn: $store.thinking)
            toggleRow("우선 처리",
                      store.priority ? "on — 표준의 1.75~2배" : "off — 표준 요금",
                      isOn: $store.priority)
        }
    }

    private func optLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(Color.tlText2).padding(.bottom, 9)
    }

    private func fieldBox(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .font(.system(size: 16))
            .lineLimit(2...8)
            .focused($focus, equals: field)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toneChip(_ t: Tone) -> some View {
        let on = m.tone == t.id
        let ok = m.toneAvailable(t.id)
        return Button {
            withAnimation(.snappy(duration: 0.22)) { m.tone = on ? "none" : t.id }
        } label: {
            HStack(spacing: 6) {
                if t.id == "character" {
                    TLAvatarView(size: 22, placeholderTint: on ? Color.tlOnAccent : Color.tlText2)
                    Text(TLPrompt.characterToneName(store.charName))
                } else {
                    Text(t.name)
                }
            }
            .font(.system(size: 14, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.tlOnAccent : Color.primary)
            .padding(.horizontal, t.id == "character" ? 8 : 13)
            .frame(height: 34)
            .background(on ? Color.tlAccent : Color.tlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .tapHaptic()
        .disabled(!ok)
        .opacity(ok ? 1 : 0.35)
    }

    private func toggleRow(_ name: String, _ desc: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Divider().padding(.top, 14)
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 16))
                    Text(desc).font(.system(size: 12.5)).foregroundStyle(Color.tlText3)
                }
            }
            .tint(.tlAccent)
            .changeHaptic(isOn.wrappedValue)
            .padding(.top, 14)
        }
    }

    // MARK: 결과

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(m.resultLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.tlText2)
                Spacer()
                if !m.result.isEmpty && !m.busy {
                    viewOpt(active: m.pronOpen, label: "독음") {
                        if m.pronLoading { ProgressView().controlSize(.mini) } else { Text("독음") }
                    } action: { m.togglePron() }
                    if m.canCheckEdited {
                        viewOpt(active: m.checkText != nil, label: "문법") {
                            if m.checkLoading { ProgressView().controlSize(.mini) } else { Text("문법") }
                        } action: { m.checkEdited() }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    viewOpt(active: false, label: "크게 보기") {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .semibold))
                    } action: { showBig = true }
                }
            }
            .frame(minHeight: 26)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if m.busy && !m.streaming {
                TLLoadingDots()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else if m.mode == .image, let img = m.overlayImage, !m.overlay.isEmpty, m.fbMessages.isEmpty {
                overlayResult(img)
            } else if !m.result.isEmpty && m.pronOpen && m.outLang == "ja" {
                // 독음을 켜면 한자 위에 후리가나. 복사에는 안 들어간다.
                TLRubyText(text: m.result, fontSize: resultFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            } else if !m.result.isEmpty {
                TLSelectableText(text: m.result, fontSize: resultFont, lineSpacing: resultFont * 0.42,
                                 editable: m.mode == .translate && !m.busy && !m.fbBusy,
                                 onEdit: { m.editResult($0) }) { kind, text, range in
                    dictTarget = TLDictTarget(text: text, range: range, mode: kind)
                    Haptics.light()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
            } else if m.error.isEmpty {
                Text("번역 결과가 여기에 표시됩니다.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.tlText3)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }

            if !m.error.isEmpty {
                Text(m.error)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.tlRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.tlRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }

            if m.succeeded && m.mode == .translate { metaPills }

            if !m.comment.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("번역 코멘트").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.tlAccentDark)
                    Text(m.comment).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(Color.tlAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            if m.pronOpen, let pron = m.pronText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("독음").font(.system(size: 12)).foregroundStyle(Color.tlText2)
                    Text(pron)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.tlText2)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .transition(.opacity)
            }

            if let c = m.checkText { checkBox(c) }

            if m.showBackTranslation { backTranslation }

            resultFooter
        }
        .tlCard()
        .animation(.easeOut(duration: 0.2), value: m.comment.isEmpty)
    }

    /// 고친 결과의 문법 체크 — 기존 문법 체크와 같은 형식으로 보여 주고, 수정 표현이 있으면 바로 넣는다
    private func checkBox(_ c: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("문법 체크").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.tlAccentDark)
                Spacer()
                Button { withAnimation(.snappy(duration: 0.2)) { m.checkText = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.tlText3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("닫기")
            }
            Text(c).font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if m.checkFix != nil {
                TLFillButton(title: "수정 표현 넣기", active: true) { m.applyCheckFix() }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    private func viewOpt<L: View>(active: Bool, label: String, @ViewBuilder content: () -> L,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.tlOnAccent : Color.tlText2)
                .padding(.horizontal, 12)
                .frame(minWidth: 34, minHeight: 28)
                .background(active ? Color.tlAccent : Color.tlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .tapHaptic()
        .accessibilityLabel(label)
    }

    private func overlayResult(_ img: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TLOverlayView(image: img, items: m.overlay)
            HStack(spacing: 10) {
                Button { m.toggleMakeImage() } label: {
                    Text(m.makingImage ? "만드는 중… 탭하면 취소" : (m.madeImage == nil ? "이미지로 만들기" : "다시 만들기"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(m.makingImage ? Color.tlText2 : Color.tlOnAccent)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(m.makingImage ? Color.tlFill : Color.tlAccent,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .tapHaptic()
                Text("탭하면 원문").font(.system(size: 12)).foregroundStyle(Color.tlText3)
            }
            if let made = m.madeImage {
                Image(uiImage: made)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 2)
                HStack(spacing: 6) {
                    TLFillButton(title: "이미지 저장") { m.saveMadeImage() }
                    ShareLink(item: Image(uiImage: made), preview: SharePreview("번역된 이미지", image: Image(uiImage: made))) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .frame(width: 34, height: 34)
                            .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var backTranslation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button { m.toggleBackTranslation() } label: {
                HStack {
                    Text("한국어로 다시 읽기").font(.system(size: 14)).foregroundStyle(.primary)
                    Spacer()
                    if m.btLoading {
                        TLLoadingDots(size: 5)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.tlText3)
                            .rotationEffect(.degrees(m.btOpen ? 180 : 0))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if m.btOpen, let bt = m.btText {
                VStack(alignment: .leading, spacing: 10) {
                    Text(highlighted(bt, m.btMarks))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.tlText2)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !m.btWarn.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                            Text(m.btWarn).font(.system(size: 12.5)).lineSpacing(3)
                        }
                        .foregroundStyle(Color.tlWarn)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    /// 어긋난 숫자를 역번역문에서 직접 짚어 준다
    private func highlighted(_ text: String, _ marks: [String]) -> AttributedString {
        var a = AttributedString(text)
        for n in marks {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: n) {
                a[r].backgroundColor = Color.tlWarn.opacity(0.18)
                a[r].foregroundColor = Color.primary
                from = r.upperBound
            }
        }
        return a
    }

    @ViewBuilder
    private var metaPills: some View {
        let pol = m.politeness
        let sugs = m.glossarySuggestions
        if !pol.isEmpty || m.usedPriority || !m.btWarn.isEmpty || !sugs.isEmpty {
            TLFlow(spacing: 5) {
                if !pol.isEmpty { pill(pol) }
                if m.usedPriority { pill("우선 처리") }
                if !m.btWarn.isEmpty {
                    Text("확인 권장")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.tlWarn)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.tlWarn.opacity(0.13), in: Capsule())
                }
                ForEach(sugs, id: \.self) { s in
                    HStack(spacing: 0) {
                        Button { m.acceptSuggestion(s) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 9, weight: .heavy))
                                Text(s.x + " → " + s.k)
                            }
                            .padding(.leading, 10).padding(.trailing, 6)
                            .frame(height: 24)
                        }
                        .buttonStyle(.plain)
                        Button { withAnimation { m.dismissSuggestion(s) } } label: {
                            Text("×").padding(.leading, 2).padding(.trailing, 9).frame(height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("다시 묻지 않기")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tlAccentDark)
                    .background(Color.tlAccent.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    private func pill(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(Color.tlText2)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.tlFill, in: Capsule())
    }

    private var resultFooter: some View {
        HStack(spacing: 6) {
            Button { m.toggleTTS() } label: {
                Group {
                    if m.ttsLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: audio.playing == "result" ? "stop.fill" : "speaker.wave.2") }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.tlText2)
                .frame(width: 34, height: 34)
                .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .tapHaptic()
            .disabled(m.result.isEmpty)
            .accessibilityLabel("읽어 주기")
            brandButton("LINE", color: Color(red: 0x06 / 255, green: 0xC7 / 255, blue: 0x55 / 255), url: "line://")
            brandButton("𝕏", color: .black, url: "twitter://")
            Spacer()
            TLFillButton(title: "원문+번역") { m.copyBoth() }
            TLFillButton(title: "복사") { m.copyResult() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// 복사한 뒤 바로 대화하러 넘어간다
    private func brandButton(_ text: String, color: Color, url: String) -> some View {
        Button {
            if !m.result.isEmpty { UIPasteboard.general.string = TLText.cleanForCopy(m.result) }
            if let u = URL(string: url) { openURL(u) }
        } label: {
            Text(text)
                .font(.system(size: text.count > 2 ? 9 : 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .tapHaptic()
        .accessibilityLabel(text == "LINE" ? "LINE" : "X")
    }

    // MARK: 피드백

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("번역 피드백")
                .font(.system(size: 13))
                .foregroundStyle(Color.tlText2)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, m.fbMessages.isEmpty ? 6 : 0)

            if !m.fbMessages.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(m.fbMessages.enumerated()), id: \.element.id) { i, msg in
                        fbRow(msg)
                        if i < m.fbMessages.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 16)
            }

            if m.fbBusy {
                TLLoadingDots(size: 6).padding(.horizontal, 16).padding(.vertical, 8)
            }

            TLFlow(spacing: 6) {
                ForEach(store.chips(m.outLang)) { c in
                    Button { m.sendFeedback(c.prompt) } label: {
                        Text(c.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Color.tlFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .tapHaptic()
                    .disabled(m.fbBusy || m.busy)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $fbText, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .focused($focus, equals: .feedback)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    let t = fbText
                    fbText = ""
                    m.sendFeedback(t)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.tlOnAccent)
                        .frame(width: 36, height: 36)
                        .tlAccentGlass()
                }
                .buttonStyle(.plain)
                .tapHaptic()
                .disabled(fbText.trimmed.isEmpty || m.fbBusy || m.busy)
                .opacity(fbText.trimmed.isEmpty ? 0.5 : 1)
                .padding(.bottom, 1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .tlCard()
    }

    private func fbRow(_ msg: FbMsg) -> some View {
        let user = msg.role == "user"
        return (Text(user ? "나  " : "AI  ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(user ? Color.tlText3 : Color.tlAccent)
                + Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundColor(user ? Color.tlText2 : Color.primary))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
    }
}

/// 번역 화면 스크롤 위치 (맨 위가 0, 내려갈수록 음수)
struct TLScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// iOS 18+ 는 스크롤 위치를 시스템에서 바로 받는다 (내려간 거리, 위로 당기면 음수)
struct TLScrollWatch: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentOffset.y + g.contentInsets.top
            } action: { _, y in
                onChange(y)
            }
        } else {
            content
        }
    }
}
