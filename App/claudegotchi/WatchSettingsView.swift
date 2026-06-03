import SwiftUI
import AppKit
import GRDB
import PetCore

@MainActor
final class WatchSettingsModel: ObservableObject {
    @Published var repos: [WatchedRepo] = []
    @Published var authorsByRepo: [Int64: [WatchedAuthor]] = [:]

    @Published var newSlug = ""
    @Published var newLocalPath = ""
    @Published var newEnabled = true
    @Published var slugError: String?
    @Published var pathError: String?

    @Published var testConnectionState: TestState = .idle
    @Published var selfLogin: String?

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    let db: DatabaseQueue
    let github: GitHubClient
    let git: GitRunner

    init(db: DatabaseQueue, github: GitHubClient, git: GitRunner) {
        self.db = db
        self.github = github
        self.git = git
    }

    var canAddRepo: Bool {
        slugError == nil && pathError == nil && !newSlug.isEmpty
    }

    func load() {
        repos = (try? PRStore.watchedRepos(in: db)) ?? []
        var map: [Int64: [WatchedAuthor]] = [:]
        for repo in repos {
            if let id = repo.id {
                map[id] = (try? PRStore.authors(repoId: id, in: db)) ?? []
            }
        }
        authorsByRepo = map
    }

    func validateSlug() {
        if newSlug.isEmpty { slugError = nil; return }
        slugError = RefValidator.isValidSlug(newSlug) ? nil : "无效的 owner/name"
    }

    func validatePath() {
        pathError = nil
        let trimmed = newLocalPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }  // blank path is allowed (status-only)
        let url = URL(fileURLWithPath: trimmed)
        guard git.isRepo(url) else { pathError = "不是 git 仓库"; return }
        guard RefValidator.isValidSlug(newSlug) else { pathError = "请先填写有效的 owner/name"; return }
        let remote = (try? git.remoteSlug(url)) ?? nil
        if remote != newSlug {
            pathError = "本地仓库 origin 与 owner/name 不匹配"
        }
    }

    func chooseLocalPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            newLocalPath = url.path
            validatePath()
        }
    }

    func addRepo() {
        validateSlug(); validatePath()
        guard canAddRepo else { return }
        let path = newLocalPath.trimmingCharacters(in: .whitespaces)
        do {
            let repo = try PRStore.addRepo(
                slug: newSlug, localPath: path.isEmpty ? nil : path, enabled: newEnabled, in: db
            )
            if let login = selfLogin, RefValidator.isValidLogin(login) {
                try PRStore.addAuthor(repoId: repo.id!, login: login, in: db)
            }
            newSlug = ""; newLocalPath = ""; newEnabled = true
            slugError = nil; pathError = nil
            load()
        } catch {
            slugError = "保存失败（slug 可能重复）"
        }
    }

    func removeRepo(_ repo: WatchedRepo) {
        guard let id = repo.id else { return }
        try? PRStore.removeRepo(id: id, in: db)
        load()
    }

    func addAuthor(repoId: Int64, login: String) -> String? {
        guard RefValidator.isValidLogin(login) else { return "无效的用户名" }
        try? PRStore.addAuthor(repoId: repoId, login: login, in: db)
        load()
        return nil
    }

    func removeAuthor(_ author: WatchedAuthor) {
        guard let id = author.id else { return }
        try? PRStore.removeAuthor(id: id, in: db)
        load()
    }

    func seedSelfLogin() {
        if let login = try? github.selfLogin(), !login.isEmpty {
            selfLogin = login
        }
    }

    func testConnection() {
        testConnectionState = .running
        DispatchQueue.global().async { [github] in
            let result: TestState
            do {
                let login = try github.selfLogin()
                result = login.isEmpty ? .failed("未登录") : .ok(login)
            } catch let e as GitHubClientError {
                switch e {
                case .commandFailed(_, let stderr): result = .failed(LogRedactor.redact(stderr))
                case .decodeFailed: result = .failed("解析失败")
                }
            } catch {
                result = .failed(LogRedactor.redact("\(error)"))
            }
            DispatchQueue.main.async {
                self.testConnectionState = result
                if case .ok(let login) = result { self.selfLogin = login }
            }
        }
    }
}

struct WatchSettingsView: View {
    @StateObject private var model: WatchSettingsModel

    init(db: DatabaseQueue, github: GitHubClient, git: GitRunner, config: ConfigYAML) {
        _model = StateObject(wrappedValue: WatchSettingsModel(db: db, github: github, git: git))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("监控仓库").font(.headline)
            addRepoForm
            Divider()
            repoList
            Divider()
            testConnectionRow
        }
        .padding()
        .frame(minWidth: 420)
        .onAppear {
            model.seedSelfLogin()
            model.load()
        }
    }

    private var addRepoForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("owner/name", text: $model.newSlug)
                    .onChange(of: model.newSlug) { _ in model.validateSlug() }
                Toggle("启用", isOn: $model.newEnabled)
            }
            if let err = model.slugError {
                Text(err).font(.caption).foregroundColor(.red)
            }
            HStack {
                TextField("本地路径（可选）", text: $model.newLocalPath)
                    .onChange(of: model.newLocalPath) { _ in model.validatePath() }
                Button("选择…") { model.chooseLocalPath() }
            }
            if let err = model.pathError {
                Text(err).font(.caption).foregroundColor(.red)
            }
            Button("添加仓库") { model.addRepo() }
                .disabled(!model.canAddRepo)
        }
    }

    private var repoList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.repos, id: \.id) { repo in
                    RepoRow(repo: repo,
                            authors: model.authorsByRepo[repo.id ?? -1] ?? [],
                            model: model)
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private var testConnectionRow: some View {
        HStack {
            Button("测试连接") { model.testConnection() }
            switch model.testConnectionState {
            case .idle: EmptyView()
            case .running: ProgressView().controlSize(.small)
            case .ok(let login): Text("✅ \(login)").font(.caption).foregroundColor(.green)
            case .failed(let msg):
                Text("⚠️ \(msg)").font(.caption).foregroundColor(.red)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }
}

private struct RepoRow: View {
    let repo: WatchedRepo
    let authors: [WatchedAuthor]
    @ObservedObject var model: WatchSettingsModel

    @State private var newAuthor = ""
    @State private var authorError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repo.slug).font(.subheadline.bold())
                    .lineLimit(1).truncationMode(.middle)
                if !repo.enabled { Text("已停用").font(.caption).foregroundColor(.secondary) }
                Spacer()
                Button(role: .destructive) { model.removeRepo(repo) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if let path = repo.localPath {
                Text(path).font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            authorChips
            HStack {
                TextField("添加作者", text: $newAuthor)
                Button("添加") {
                    authorError = model.addAuthor(repoId: repo.id ?? -1, login: newAuthor)
                    if authorError == nil { newAuthor = "" }
                }
            }
            if let err = authorError {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }

    private var authorChips: some View {
        WrapHStack {
            ForEach(authors, id: \.id) { author in
                HStack(spacing: 2) {
                    Text(author.login).font(.caption)
                    Button { model.removeAuthor(author) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(8)
            }
        }
    }
}

private struct WrapHStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
