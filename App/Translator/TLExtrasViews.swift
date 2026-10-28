import PhotosUI
import SwiftUI
import UIKit

// 2단계 화면 조각: 고르면 뜻·바꾸기가 뜨는 결과 글 · 사전 시트 · 사진 덮어쓰기 · 크게 보기 · 카메라

// MARK: 결과 글 (UITextView)

/// 글을 고르면 시스템 편집 메뉴에 '뜻'·'바꾸기'가 붙는다. 복사·찾아보기 같은 기본 메뉴는 그대로 둔다.
struct TLSelectableText: UIViewRepresentable {
    enum Action { case meaning, alt }

    let text: String
    let fontSize: CGFloat
    var lineSpacing: CGFloat = 0
    /// 결과를 그 자리에서 고칠 수 있게
    var editable = false
    var onEdit: ((String) -> Void)? = nil
    let onAction: (Action, String, NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.adjustsFontForContentSizeCategory = false
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        tv.isEditable = editable
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: style
        ]
        tv.typingAttributes = attrs
        // 고치는 중엔 글이 같으면 다시 넣지 않는다 (커서가 끝으로 튀지 않게)
        if tv.text != text || tv.font?.pointSize != fontSize {
            tv.attributedText = NSAttributedString(string: text, attributes: attrs)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? UIScreen.main.bounds.width - 64
        let fit = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: ceil(fit.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TLSelectableText
        init(_ p: TLSelectableText) { parent = p }

        func textViewDidChange(_ textView: UITextView) {
            parent.onEdit?(textView.text ?? "")
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let ns = (textView.text ?? "") as NSString
            guard range.length > 0, NSMaxRange(range) <= ns.length else { return UIMenu(children: suggestedActions) }
            let picked = ns.substring(with: range).trimmed
            // 너무 길게 고르면 사전·바꾸기가 의미 없다
            guard !picked.isEmpty, picked.count <= 60 else { return UIMenu(children: suggestedActions) }
            let meaning = UIAction(title: "뜻") { [weak self] _ in self?.parent.onAction(.meaning, picked, range) }
            let alt = UIAction(title: "바꾸기") { [weak self] _ in self?.parent.onAction(.alt, picked, range) }
            let ours: [UIMenuElement] = [meaning, alt]
            return UIMenu(children: ours + suggestedActions)
        }
    }
}

// MARK: 사전 · 바꾸기 시트

struct TLDictTarget: Identifiable {
    let id = UUID()
    let text: String
    let range: NSRange
    var mode: TLSelectableText.Action
}

struct TLDictSheet: View {
    @ObservedObject var m: TranslatorModel
    @State var target: TLDictTarget
    @State private var reading = ""
    @State private var meaning = ""
    @State private var loading = false
    @State private var altText = ""
    @State private var altStatus = ""
    @State private var altBusy = false
    @FocusState private var altFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(target.text.count > 36 ? String(target.text.prefix(36)) + "…" : target.text)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .textSelection(.enabled)
                Spacer()
                TLCircleButton(symbol: "xmark", size: 32, label: "닫기") { dismiss() }
            }
            HStack(spacing: 8) {
                tab("뜻", on: target.mode == .meaning) { target.mode = .meaning; loadMeaning() }
                tab("바꾸기", on: target.mode == .alt) { target.mode = .alt; altFocused = true }
            }

            if target.mode == .meaning {
                VStack(alignment: .leading, spacing: 8) {
                    if !reading.isEmpty {
                        Text(reading).font(.system(size: 15)).foregroundStyle(Color.tlAccentDark)
                    }
                    if loading {
                        Text("찾는 중…").font(.system(size: 14)).foregroundStyle(Color.tlText3)
                    } else {
                        Text(meaning)
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    TextField("예) 더 정중하게 / 다른 단어로", text: $altText)
                        .font(.system(size: 16))
                        .focused($altFocused)
                        .submitLabel(.send)
                        .onSubmit(applyAlt)
                        .padding(.horizontal, 14).frame(height: 42)
                        .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button(action: applyAlt) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.tlOnAccent)
                            .frame(width: 40, height: 40)
                            .tlAccentGlass()
                    }
                    .buttonStyle(.plain)
                    .disabled(altBusy || altText.trimmed.isEmpty)
                    .opacity(altText.trimmed.isEmpty ? 0.5 : 1)
                }
                if !altStatus.isEmpty {
                    Text(altStatus).font(.system(size: 13)).foregroundStyle(Color.tlText2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.fraction(0.42), .large])
        .presentationDragIndicator(.visible)
        .tint(.tlAccent)
        .onAppear {
            if target.mode == .meaning { loadMeaning() } else { altFocused = true }
        }
    }

    private func tab(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        TLFillButton(title: title, active: on, action: action)
    }

    private func loadMeaning() {
        guard meaning.isEmpty, !loading else { return }
        loading = true
        let prompt = TLExtras.dictPrompt(word: target.text, langName: m.outName)
        Task {
            do {
                // 기기 안 AI 먼저, 못 쓰면 Gemini
                let out = try await TLLocal.askLocalFirst(prompt, maxTokens: 512)
                let p = TLExtras.parseDict(out)
                reading = p.reading
                meaning = p.meaning
                TLHaptic.tick()
            } catch {
                meaning = error.localizedDescription
            }
            loading = false
        }
    }

    private func applyAlt() {
        let req = altText.trimmed
        guard !req.isEmpty, !altBusy else { return }
        let store = TLStore.shared
        guard store.hasKey else { altStatus = "API 키를 설정해주세요."; return }
        altBusy = true
        altStatus = "바꾸는 중..."
        let prompt = TLExtras.altPrompt(full: m.result, selection: target.text, request: req)
        Task {
            do {
                let out = try await Gemini.ask(model: store.effectiveModel, key: store.apiKey.trimmed, prompt: prompt, maxTokens: 256)
                let rep = TLExtras.cleanAlt(out)
                if rep.isEmpty { throw GeminiError(message: "결과를 받지 못했어요.") }
                if m.replaceInResult(target.text, with: rep, hint: target.range) { dismiss() }
                else { altStatus = "바꿀 위치를 찾지 못했어요." }
            } catch {
                altStatus = error.localizedDescription
            }
            altBusy = false
        }
    }
}

// MARK: 사진 덮어쓰기

/// 원본 사진 위에 번역문을 박스마다 덮는다. 박스를 누르면 원문이 보인다.
struct TLOverlayView: View {
    let image: UIImage
    let items: [OverlayItem]
    @State private var showingSrc: Set<UUID> = []
    @State private var colors: [UUID: (bg: Color, fg: Color)] = [:]

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    ForEach(items) { it in box(it, in: geo.size) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: items.count) {
                var c: [UUID: (bg: Color, fg: Color)] = [:]
                for it in items { if let col = TLExtras.boxColor(image, it.box) { c[it.id] = col } }
                colors = c
            }
    }

    private func box(_ it: OverlayItem, in size: CGSize) -> some View {
        let b = it.box
        let x = CGFloat(b[1]) / 1000 * size.width, y = CGFloat(b[0]) / 1000 * size.height
        let w = CGFloat(b[3] - b[1]) / 1000 * size.width, h = CGFloat(b[2] - b[0]) / 1000 * size.height
        let src = showingSrc.contains(it.id) && !it.src.isEmpty
        let col = colors[it.id]
        // 번역문이 원문보다 길어지는 일이 흔해서, 9pt 까지 줄여도 안 들어가면 위아래로 조금 넓힌다
        let grow: CGFloat = h < 22 ? min(2.4, 22 / max(h, 1)) : 1
        let hh = h * grow
        return Text(src ? it.src : it.dst)
            .font(.system(size: max(9, h * 0.78)))
            .minimumScaleFactor(max(0.05, 9 / max(h * 0.78, 9)))
            .multilineTextAlignment(.center)
            .foregroundStyle(col?.fg ?? Color.primary)
            .frame(width: w, height: hh)
            .background(col?.bg ?? Color.tlCard)
            .position(x: x + w / 2, y: y + h / 2)
            .onTapGesture {
                if src { showingSrc.remove(it.id) } else { showingSrc.insert(it.id) }
                TLHaptic.select()
            }
    }
}

// MARK: 크게 보기

/// 상대에게 화면을 보여 줄 때. 세로로 든 폰은 내용을 90도 돌려 눕혀 읽게 한다.
struct TLBigView: View {
    let text: String
    let sub: String
    @Environment(\.dismiss) private var dismiss
    @State private var rotated = true

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let rot = rotated && !landscape
            let boxW = (rot ? geo.size.height : geo.size.width) - 52
            let boxH = (rot ? geo.size.width : geo.size.height) - 112
            ZStack {
                Color.tlCard.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(text)
                        .font(.system(size: 170, weight: .medium))
                        .tracking(-0.4)
                        .lineSpacing(6)
                        .minimumScaleFactor(0.07)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !sub.isEmpty {
                        Divider()
                        Text(sub)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.tlText3)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                }
                .frame(width: max(120, boxW), height: max(120, boxH))
                .rotationEffect(.degrees(rot ? 90 : 0))
                .animation(.easeInOut(duration: 0.22), value: rot)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

                VStack {
                    HStack(spacing: 8) {
                        Spacer()
                        if !landscape {
                            TLCircleButton(symbol: "rotate.right", label: "돌리기") { rotated.toggle() }
                        }
                        TLCircleButton(symbol: "xmark", label: "닫기") { dismiss() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    Spacer()
                }
            }
        }
        .statusBarHidden()
    }
}

// MARK: 카메라

struct TLCameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: TLCameraPicker
        init(_ p: TLCameraPicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let im = info[.originalImage] as? UIImage { parent.onPick(im) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: 후리가나 결과 (독음을 켰을 때)

/// 한자 위에 읽기를 작게 단다. 낱말마다 [읽기 / 글자]를 위아래로 쌓아 직접 줄을 짠다.
/// (UILabel 루비는 줄 높이 계산에 안 들어가 윗줄 밖으로 삐져나가 잘렸다)
/// 이때는 글 고르기·고치기를 쉰다. 복사 버튼은 글자만 복사한다.
struct TLRubyText: View {
    let text: String
    let fontSize: CGFloat

    private struct Unit { let base: String; let ruby: String? }

    /// 줄(문단)별 낱말 조각. 한자 덩어리는 읽기와 한 조각, 나머지는 글자 하나씩 (영숫자는 낱말째)
    private var paragraphs: [[Unit]] {
        var paras: [[Unit]] = [[]]
        for seg in TLLocal.rubySegments(text) {
            if let r = seg.ruby, !seg.text.contains("\n") {
                paras[paras.count - 1].append(Unit(base: seg.text, ruby: r))
                continue
            }
            var word = ""
            func flush() { if !word.isEmpty { paras[paras.count - 1].append(Unit(base: word, ruby: nil)); word = "" } }
            for ch in seg.text {
                if ch == "\n" { flush(); paras.append([]); continue }
                if ch.isASCII && (ch.isLetter || ch.isNumber) { word.append(ch); continue }
                flush()
                paras[paras.count - 1].append(Unit(base: String(ch), ruby: nil))
            }
            flush()
        }
        return paras
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.3) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, units in
                if units.isEmpty {
                    Text(" ").font(.system(size: fontSize))
                } else {
                    TLFlow(spacing: 0, lineSpacing: fontSize * 0.2) {
                        ForEach(Array(units.enumerated()), id: \.offset) { _, u in unit(u) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unit(_ u: Unit) -> some View {
        VStack(spacing: 0) {
            Text(u.ruby ?? " ")
                .font(.system(size: fontSize * 0.5))
                .foregroundStyle(u.ruby == nil ? Color.clear : Color.tlText2)
                .lineLimit(1)
                .fixedSize()
            Text(u.base)
                .font(.system(size: fontSize))
                .fixedSize()
        }
    }
}
