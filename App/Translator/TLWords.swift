import SwiftUI
import UIKit

// 표현 노트와 공부 기록. HTML 판 localStorage 의 study_words · study_wrong · study_seen · study_opts 를
// 같은 JSON 그대로 'tl.' 를 붙여 UserDefaults 에 둔다. 백업 파일을 양쪽에서 주고받을 수 있게.

struct TLWord: Codable, Hashable, Identifiable {
    var ja: String
    var yomi: String
    var ko: String
    var tag: String
    var at: Double
    var id: String { ja }

    init(ja: String, yomi: String = "", ko: String = "", tag: String = "", at: Double = Date().timeIntervalSince1970 * 1000) {
        self.ja = ja; self.yomi = yomi; self.ko = ko; self.tag = tag; self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ja = (try? c.decode(String.self, forKey: .ja)) ?? ""
        yomi = (try? c.decode(String.self, forKey: .yomi)) ?? ""
        ko = (try? c.decode(String.self, forKey: .ko)) ?? ""
        tag = (try? c.decode(String.self, forKey: .tag)) ?? ""
        at = (try? c.decode(Double.self, forKey: .at)) ?? 0
    }
}

struct TLWrong: Codable, Hashable, Identifiable {
    var ko: String
    var mine: String
    var v: String
    var at: Double
    var id: String { ko }

    init(ko: String, mine: String, v: String, at: Double = Date().timeIntervalSince1970 * 1000) {
        self.ko = ko; self.mine = mine; self.v = v; self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ko = (try? c.decode(String.self, forKey: .ko)) ?? ""
        mine = (try? c.decode(String.self, forKey: .mine)) ?? ""
        v = (try? c.decode(String.self, forKey: .v)) ?? "soso"
        at = (try? c.decode(Double.self, forKey: .at)) ?? 0
    }
}

struct TLStudyOpts: Codable, Equatable {
    var range: String
    var topics: [String]
    var count: Int

    static let topicsAll = ["일상", "약속", "식사", "감정", "거절·양해", "리액션", "덕질", "요즘 말"]
    static let counts = [5, 10, 20]

    init(range: String = "daily", topics: [String] = ["일상", "약속", "감정"], count: Int = 10) {
        self.range = range; self.topics = topics; self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let r = (try? c.decode(String.self, forKey: .range)) ?? "daily"
        range = ["daily", "words", "wrong"].contains(r) ? r : "daily"
        let t = (try? c.decode([String].self, forKey: .topics)) ?? []
        topics = t.isEmpty ? ["일상", "약속", "감정"] : t
        let n = (try? c.decode(Int.self, forKey: .count)) ?? 10
        count = Self.counts.contains(n) ? n : 10
    }
}

/// 다른 화면에서 표현을 노트에 넣을 때: `TLNotes.addWord(ja:yomi:ko:tag:)`
enum TLNotes {
    private static var d: UserDefaults { .standard }

    private static func read<T: Decodable>(_ key: String, _ t: T.Type) -> T? {
        guard let s = d.string(forKey: "tl." + key), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(t, from: data)
    }
    private static func write<T: Encodable>(_ key: String, _ v: T) {
        if let data = try? JSONEncoder().encode(v), let s = String(data: data, encoding: .utf8) {
            d.set(s, forKey: "tl." + key)
        }
    }

    static var words: [TLWord] { (read("study_words", [TLWord].self) ?? []).filter { !$0.ja.isEmpty } }
    static var wrongs: [TLWrong] { (read("study_wrong", [TLWrong].self) ?? []).filter { !$0.ko.isEmpty } }

    @discardableResult
    static func addWord(ja: String, yomi: String = "", ko: String = "", tag: String = "") -> TLWord? {
        let j = ja.trimmed
        if j.isEmpty { return nil }
        let row = TLWord(ja: j, yomi: yomi, ko: ko, tag: tag)
        var list = words.filter { $0.ja != j }
        list.insert(row, at: 0)
        if list.count > 300 { list.removeLast(list.count - 300) }
        write("study_words", list)
        return row
    }
    static func dropWord(_ ja: String) { write("study_words", words.filter { $0.ja != ja }) }

    static func addWrong(ko: String, mine: String, v: String) {
        var list = wrongs.filter { $0.ko != ko }
        list.insert(TLWrong(ko: ko, mine: mine, v: v), at: 0)
        if list.count > 200 { list.removeLast(list.count - 200) }
        write("study_wrong", list)
    }
    static func dropWrong(_ ko: String) { write("study_wrong", wrongs.filter { $0.ko != ko }) }

    /// 방금 낸 문장은 잠깐 피한다. 안 그러면 비슷한 게 계속 나온다.
    static var seen: [String] { read("study_seen", [String].self) ?? [] }
    static func markSeen(_ list: [String]) { write("study_seen", Array((list + seen).prefix(60))) }

    static var opts: TLStudyOpts {
        get { read("study_opts", TLStudyOpts.self) ?? TLStudyOpts() }
        set { write("study_opts", newValue) }
    }
}

// MARK: 공용 모양 (공부 · 노트)

/// 판정 배지 — 그대로 써도 됨 / 통하긴 함 / 다시
struct TLVerdictPill: View {
    let v: String
    let text: String

    private var fg: Color {
        switch v {
        case "ok": return .tlAccentDark
        case "redo": return .tlRed
        default: return Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0xF0 / 255, green: 0xB9 / 255, blue: 0x53 / 255, alpha: 1)
            : UIColor(red: 0x8A / 255, green: 0x5A / 255, blue: 0, alpha: 1) })
        }
    }
    private var bg: Color {
        switch v {
        case "ok": return Color.tlAccent.opacity(0.12)
        case "redo": return Color.tlRed.opacity(0.12)
        default: return Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 190 / 255, blue: 80 / 255, alpha: 0.16)
            : UIColor(red: 168 / 255, green: 116 / 255, blue: 0, alpha: 0.13) })
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(bg, in: Capsule())
            .fixedSize()
    }
}

/// 표현 옆 작은 태그 (어디서나 · 친구끼리 …)
struct TLTagPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(Color.tlText2)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Color.tlFill, in: Capsule())
            .fixedSize()
            .padding(.top, 2)
    }
}

/// 공부 화면의 큰 초록 버튼 모양
struct TLGoLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.tlOnAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
            .tlAccentGlass(cornerRadius: 14)
    }
}

/// 화면 아래 잠깐 뜨는 알림
struct TLToastView: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .liquidGlass()
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 두 칸 세그먼트 (배운 말 / 틀린 문제, 5 / 10 / 20)
struct TLSeg<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items.indices, id: \.self) { i in
                let on = items[i].0 == selection
                Button {
                    Haptics.selection()
                    withAnimation(.snappy(duration: 0.22)) { selection = items[i].0 }
                } label: {
                    Text(items[i].1)
                        .font(.system(size: 15, weight: on ? .bold : .semibold))
                        .foregroundStyle(on ? Color.primary : Color.tlText2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(on ? Color.tlCard : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.tlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: 표현 노트

struct TLWordsPage: View {
    @State private var tab = "words"
    @State private var words: [TLWord] = []
    @State private var wrongs: [TLWrong] = []
    @State private var toast: String?

    private var onWords: Bool { tab == "words" }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.tlBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 10) {
                    TLSeg(items: [("words", "배운 말 \(words.count)"), ("wrong", "틀린 문제 \(wrongs.count)")],
                          selection: $tab)
                    listCard
                    NavigationLink(value: TLRoute.study) {
                        TLGoLabel(title: onWords ? "이 표현으로 문제 풀기" : "틀린 문제 다시 풀기")
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { TLStudyLaunch.once = onWords ? "words" : "wrong" })
                    .disabled(onWords ? words.isEmpty : wrongs.isEmpty)
                    .opacity((onWords ? words.isEmpty : wrongs.isEmpty) ? 0.55 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 18)
            }
            TLToastView(text: toast)
        }
        .navigationTitle("표현 노트")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        words = TLNotes.words
        wrongs = TLNotes.wrongs
    }

    @ViewBuilder
    private var listCard: some View {
        VStack(spacing: 0) {
            if onWords {
                if words.isEmpty { none("공부를 하면 배운 말이 여기 쌓여요") }
                ForEach(Array(words.enumerated()), id: \.element.id) { i, w in
                    if i > 0 { Divider().padding(.leading, 16) }
                    wordRow(w)
                }
            } else {
                if wrongs.isEmpty { none("틀린 문제가 없어요") }
                ForEach(Array(wrongs.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider().padding(.leading, 16) }
                    wrongRow(r)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .tlCard()
    }

    private func none(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15))
            .foregroundStyle(Color.tlText3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44).padding(.horizontal, 16)
    }

    private func wordRow(_ w: TLWord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                UIPasteboard.general.string = w.ja
                Haptics.light()
                show("복사했어요")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.ja)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.tlAccentDark)
                    if !w.yomi.isEmpty {
                        Text(w.yomi).font(.system(size: 12.5)).foregroundStyle(Color.tlText3)
                    }
                    if !w.ko.isEmpty {
                        Text(w.ko).font(.system(size: 14)).foregroundStyle(Color.tlText2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !w.tag.isEmpty { TLTagPill(text: w.tag) }
            Button {
                Haptics.light()
                TLNotes.dropWord(w.ja)
                withAnimation(.snappy(duration: 0.22)) { reload() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.tlText3)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("지우기")
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 11)
    }

    private func wrongRow(_ r: TLWrong) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.ko).font(.system(size: 16))
                Text(r.mine.isEmpty ? "답을 안 씀" : r.mine)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.tlText3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TLVerdictPill(v: r.v == "redo" ? "redo" : "soso", text: r.v == "redo" ? "다시" : "통함")
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 11)
    }

    private func show(_ s: String) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { toast = s }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(.easeOut(duration: 0.25)) { if toast == s { toast = nil } }
        }
    }
}
