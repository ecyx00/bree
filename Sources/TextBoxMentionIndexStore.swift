import AppKit
import Foundation

actor TextBoxMentionIndexStore {
    static let shared = TextBoxMentionIndexStore()

    private static let fileIndexTTL: TimeInterval = 30
    private static let maxCachedFileIndexes = 8
    private static let directorySeedBatchSize = 128
    private static let maxIndexedDirectories = 2000
    private static let maxIndexedFiles = 6000
    private static let maxIndexedSkills = 800
    private static let rootSuggestionLimit = 200
    private static let suggestionLimit = 500
    private static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".next",
        ".swiftpm",
        ".vercel",
        "DerivedData",
        "Library",
        "node_modules",
        "Pods",
        "vendor"
    ]
    private static let skippedPackageDirectorySuffixes = [
        ".app",
        ".appex",
        ".bundle",
        ".dSYM",
        ".framework",
        ".kext",
        ".mdimporter",
        ".plugin",
        ".prefPane",
        ".qlgenerator",
        ".rtfd",
        ".xcframework",
        ".xcodeproj",
        ".xcworkspace",
        ".playground"
    ]

    private var fileIndexesByRoot: [String: TextBoxMentionCachedIndex] = [:]
    private var fileIndexRefreshTasks: [String: TextBoxMentionFileIndexRefreshTask] = [:]
    private var nextFileIndexRefreshTaskID: UInt64 = 0
    private var skillIndexesByRootKey: [String: TextBoxMentionCandidateIndex] = [:]
    /// Cancels in-flight scans (and therefore their `rg` children) when the store is released.
    private let scanTaskBag = TextBoxMentionScanTaskBag()
    /// Terminates any live `rg` child on app quit.
    private let willTerminateObserver = TextBoxMentionWillTerminateObserver()

    /// The index never scans `/`, the home directory or an ancestor of home: such walks touch
    /// TCC-protected folders and can run for minutes. Callers get an empty index instead.
    nonisolated static func isUnscannableRoot(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        func canonical(_ value: String) -> String {
            URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let root = canonical(path)
        let homePath = canonical(home)
        if root == "/" || root == homePath { return true }
        return homePath.hasPrefix(root + "/")
    }

    func suggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String?
    ) async -> [TextBoxMentionSuggestion] {
        switch query.kind {
        case .file:
            guard let rootDirectory = await Self.normalizedScannableDirectory(rootDirectory) else { return [] }
            return await fileSuggestions(for: query, rootDirectory: rootDirectory)
        case .skill:
            let index = await skillIndex(rootDirectory: await Self.normalizedDirectoryOffPool(rootDirectory))
            return index.rankedCandidates(
                matching: query.query,
                limit: Self.suggestionLimit,
                shouldCancel: { Task.isCancelled }
            )
                .map { $0.suggestion(trigger: query.trigger) }
        }
    }

    /// Quick Open (Cmd+P): absolute paths of indexed files (directories excluded), reusing the
    /// gitignore-aware, size-capped, TTL-cached `@file` index.
    func indexedFilePaths(rootDirectory: String?) async -> [String] {
        guard let root = await Self.normalizedScannableDirectory(rootDirectory) else { return [] }
        let index = await fileIndex(rootDirectory: root, now: Date())
        return index
            .rankedCandidates(matching: "", limit: Self.maxIndexedFiles + Self.maxIndexedDirectories)
            .filter { $0.systemImageName != "folder" }
            .map(\.targetPath)
    }

    func warmIndexes(rootDirectory: String?) async {
        let normalizedRootDirectory = await Self.normalizedDirectoryOffPool(rootDirectory)
        _ = await skillIndex(rootDirectory: normalizedRootDirectory)
        if let normalizedRootDirectory,
           await !BlockingFileSystem.run({ Self.isUnscannableRoot(normalizedRootDirectory) }) {
            _ = await fileIndex(rootDirectory: normalizedRootDirectory, now: Date())
        }
    }

    private func fileSuggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String
    ) async -> [TextBoxMentionSuggestion] {
        let now = Date()
        let trimmedQuery = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            if let cachedIndex = cachedFileIndex(rootDirectory: rootDirectory, now: now) {
                return cachedIndex.rankedCandidates(
                    matching: query.query,
                    limit: Self.suggestionLimit,
                    shouldCancel: { Task.isCancelled }
                )
                .map { $0.suggestion(trigger: query.trigger) }
            }

            refreshFileIndexInBackground(rootDirectory: rootDirectory, now: now)
            return await Self.scanRootFileSystemCandidates(rootURL: URL(
                fileURLWithPath: rootDirectory,
                isDirectory: true
            ))
            .prefix(Self.suggestionLimit)
            .map { $0.suggestion(trigger: query.trigger) }
        }

        let index = await fileIndex(rootDirectory: rootDirectory, now: now)
        if Task.isCancelled { return [] }

        var matches = index.rankedCandidates(
            matching: query.query,
            limit: Self.suggestionLimit,
            shouldCancel: { Task.isCancelled }
        )
        if Task.isCancelled { return [] }
        if matches.isEmpty {
            let refreshed = await refreshFileIndex(
                rootDirectory: rootDirectory,
                now: Date(),
                minimumStartedAt: now
            )
            if Task.isCancelled { return [] }
            matches = refreshed.rankedCandidates(
                matching: query.query,
                limit: Self.suggestionLimit,
                shouldCancel: { Task.isCancelled }
            )
            if Task.isCancelled { return [] }
        }
        return matches
            .map { $0.suggestion(trigger: query.trigger) }
    }

    private func cachedFileIndex(
        rootDirectory: String,
        now: Date
    ) -> TextBoxMentionCandidateIndex? {
        guard let cached = fileIndexesByRoot[rootDirectory] else {
            pruneFileIndexCache(now: now)
            return nil
        }
        guard now.timeIntervalSince(cached.createdAt) < Self.fileIndexTTL else {
            fileIndexesByRoot[rootDirectory] = nil
            pruneFileIndexCache(now: now)
            return nil
        }
        fileIndexesByRoot[rootDirectory] = TextBoxMentionCachedIndex(
            index: cached.index,
            createdAt: cached.createdAt,
            lastAccessedAt: now,
            refreshStartedAt: cached.refreshStartedAt
        )
        pruneFileIndexCache(now: now)
        return cached.index
    }

    private func fileIndex(
        rootDirectory: String,
        now: Date
    ) async -> TextBoxMentionCandidateIndex {
        if let cachedIndex = cachedFileIndex(rootDirectory: rootDirectory, now: now) {
            return cachedIndex
        }
        return await refreshFileIndex(rootDirectory: rootDirectory, now: now)
    }

    private func refreshFileIndex(
        rootDirectory: String,
        now: Date,
        minimumStartedAt: Date? = nil
    ) async -> TextBoxMentionCandidateIndex {
        // Coalesce concurrent refreshes: while one scan is in flight for a root,
        // additional keystrokes await the same scan instead of each spawning a
        // fresh (and expensive) `rg`/filesystem walk. The detached scan is not
        // cancelled, so a join here is correct even if the caller's lookup task is.
        let refreshTask = fileIndexRefreshTask(
            rootDirectory: rootDirectory,
            minimumStartedAt: minimumStartedAt
        )
        let index = await refreshTask.task.value
        // A superseded scan was cancelled and its result is partial: never cache it.
        if refreshTask.task.isCancelled { return index }
        storeFileIndex(
            rootDirectory: rootDirectory,
            index: index,
            refreshStartedAt: refreshTask.startedAt,
            refreshTaskID: refreshTask.id
        )
        return index
    }

    private func refreshFileIndexInBackground(rootDirectory: String, now: Date) {
        guard cachedFileIndex(rootDirectory: rootDirectory, now: now) == nil else { return }
        let refreshTask = fileIndexRefreshTask(rootDirectory: rootDirectory)
        Task { [rootDirectory, refreshTask] in
            let index = await refreshTask.task.value
            if refreshTask.task.isCancelled { return }
            self.storeFileIndex(
                rootDirectory: rootDirectory,
                index: index,
                refreshStartedAt: refreshTask.startedAt,
                refreshTaskID: refreshTask.id
            )
        }
    }

    private func fileIndexRefreshTask(
        rootDirectory: String,
        minimumStartedAt: Date? = nil
    ) -> TextBoxMentionFileIndexRefreshTask {
        if let inFlight = fileIndexRefreshTasks[rootDirectory],
           minimumStartedAt.map({ inFlight.startedAt >= $0 }) ?? true {
            return inFlight
        }

        // Superseded by a newer scan: stop the old one (and its `rg` child).
        fileIndexRefreshTasks[rootDirectory]?.task.cancel()

        let rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let scanTask = Task<TextBoxMentionCandidateIndex, Never>.detached(priority: .utility) {
            let candidates = await Self.scanFiles(rootURL: rootURL)
            return TextBoxMentionCandidateIndex(candidates: candidates)
        }
        scanTaskBag.add(scanTask)
        nextFileIndexRefreshTaskID &+= 1
        let refreshTask = TextBoxMentionFileIndexRefreshTask(
            id: nextFileIndexRefreshTaskID,
            startedAt: Date(),
            task: scanTask
        )
        fileIndexRefreshTasks[rootDirectory] = refreshTask
        return refreshTask
    }

    private func storeFileIndex(
        rootDirectory: String,
        index: TextBoxMentionCandidateIndex,
        refreshStartedAt: Date,
        refreshTaskID: UInt64
    ) {
        if let cached = fileIndexesByRoot[rootDirectory],
           cached.refreshStartedAt > refreshStartedAt {
            return
        }
        if fileIndexRefreshTasks[rootDirectory]?.id == refreshTaskID {
            fileIndexRefreshTasks[rootDirectory] = nil
        }
        let storedAt = Date()
        fileIndexesByRoot[rootDirectory] = TextBoxMentionCachedIndex(
            index: index,
            createdAt: storedAt,
            lastAccessedAt: storedAt,
            refreshStartedAt: refreshStartedAt
        )
        pruneFileIndexCache(now: storedAt)
    }

    private func pruneFileIndexCache(now: Date) {
        let expiredRoots = fileIndexesByRoot.compactMap { rootDirectory, cached in
            now.timeIntervalSince(cached.createdAt) >= Self.fileIndexTTL ? rootDirectory : nil
        }
        for rootDirectory in expiredRoots {
            fileIndexesByRoot[rootDirectory] = nil
        }

        guard fileIndexesByRoot.count > Self.maxCachedFileIndexes else { return }
        let rootsToRemove = fileIndexesByRoot
            .sorted { lhs, rhs in
                if lhs.value.lastAccessedAt != rhs.value.lastAccessedAt {
                    return lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
                }
                return lhs.key < rhs.key
            }
            .prefix(fileIndexesByRoot.count - Self.maxCachedFileIndexes)
            .map(\.key)
        for rootDirectory in rootsToRemove {
            fileIndexesByRoot[rootDirectory] = nil
        }
    }

    private func skillIndex(rootDirectory: String?) async -> TextBoxMentionCandidateIndex {
        let roots = await BlockingFileSystem.run { Self.skillSearchRoots(rootDirectory: rootDirectory) }
        let cacheKey = roots.map(\.path).joined(separator: "\n")
        if let cached = skillIndexesByRootKey[cacheKey] {
            return cached
        }
        let index = await BlockingFileSystem.run { Self.buildSkillIndex(roots: roots) }
        skillIndexesByRootKey[cacheKey] = index
        return index
    }

    private nonisolated static func buildSkillIndex(roots: [URL]) -> TextBoxMentionCandidateIndex {
        var seenPaths = Set<String>()
        var candidates: [TextBoxMentionCandidate] = []
        for (rootIndex, root) in roots.enumerated() {
            for skillURL in Self.scanSkillFiles(rootURL: root) {
                let path = skillURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                let skillName = Self.skillName(from: skillURL)
                candidates.append(TextBoxMentionCandidate(
                    title: "/\(skillName)",
                    subtitle: Self.displayPath(path),
                    targetPath: path,
                    systemImageName: "sparkle.magnifyingglass",
                    searchKey: Self.skillSearchKey(skillName: skillName, skillURL: skillURL, rootURL: root),
                    priority: rootIndex
                ))
                if candidates.count >= Self.maxIndexedSkills {
                    break
                }
            }
            if candidates.count >= Self.maxIndexedSkills {
                break
            }
        }

        return TextBoxMentionCandidateIndex(candidates: candidates)
    }

    private static func scanFiles(rootURL: URL) async -> [TextBoxMentionCandidate] {
        if let ripgrepCandidates = await scanFilesWithRipgrep(rootURL: rootURL) {
            return ripgrepCandidates
        }
        if Task.isCancelled { return [] }
        return await BlockingFileSystem.run { enumerateFiles(rootURL: rootURL) }
    }

    private static func enumerateFiles(rootURL: URL) -> [TextBoxMentionCandidate] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let rootPath = rootURL.standardizedFileURL.path
        var directoryCandidates: [TextBoxMentionCandidate] = []
        var fileCandidates: [TextBoxMentionCandidate] = []
        var seenDirectoryRelativePaths = Set<String>()
        directoryCandidates.reserveCapacity(min(maxIndexedDirectories, 256))
        fileCandidates.reserveCapacity(min(maxIndexedFiles, 1024))

        func appendDirectoryCandidate(relativePath: String, directoryURL: URL) {
            guard !relativePath.isEmpty,
                  directoryCandidates.count < maxIndexedDirectories,
                  seenDirectoryRelativePaths.insert(relativePath).inserted else {
                return
            }
            directoryCandidates.append(Self.directoryCandidate(
                relativePath: relativePath,
                directoryURL: directoryURL
            ))
        }

        while let item = enumerator.nextObject() as? URL {
            let standardizedURL = item.standardizedFileURL
            let name = standardizedURL.lastPathComponent
            let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if shouldSkipIndexedDirectoryName(name) {
                    enumerator.skipDescendants()
                    continue
                }
                appendDirectoryCandidate(
                    relativePath: Self.relativePath(for: standardizedURL.path, rootPath: rootPath),
                    directoryURL: standardizedURL
                )
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let relativePath = Self.relativePath(for: standardizedURL.path, rootPath: rootPath)
            if fileCandidates.count < maxIndexedFiles {
                fileCandidates.append(Self.fileCandidate(
                    relativePath: relativePath,
                    fileURL: standardizedURL,
                    fileName: name
                ))
            }

            if fileCandidates.count >= maxIndexedFiles {
                break
            }
        }
        return sortedFileSystemCandidates(directoryCandidates + fileCandidates)
    }

    private static func scanRootFileSystemCandidates(rootURL: URL) async -> [TextBoxMentionCandidate] {
        let rootEntries: [(url: URL, isDirectory: Bool)] = await BlockingFileSystem.run {
            let fileManager = FileManager.default
            guard let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            return children.map(\.standardizedFileURL).compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    return shouldSkipIndexedDirectoryName(url.lastPathComponent) ? nil : (url, true)
                }
                return values?.isRegularFile == true ? (url, false) : nil
            }
        }

        let rootPath = rootURL.standardizedFileURL.path
        let candidateURLs = rootEntries.map(\.url)
        let relativePaths = candidateURLs.map {
            Self.relativePath(for: $0.path, rootPath: rootPath)
        }
        let gitIgnoreProbe = TextBoxGitIgnoreProbe(rootURL: rootURL)
        let ignoredRelativePaths = await gitIgnoreProbe.isWorkTree()
            ? await gitIgnoreProbe.ignoredRelativePaths(relativePaths)
            : []

        let directoryURLs = Set(rootEntries.filter(\.isDirectory).map(\.url))
        var candidates: [TextBoxMentionCandidate] = []
        candidates.reserveCapacity(candidateURLs.count)
        for url in candidateURLs {
            let relativePath = Self.relativePath(for: url.path, rootPath: rootPath)
            guard !relativePath.isEmpty,
                  !ignoredRelativePaths.contains(relativePath),
                  !ignoredRelativePaths.contains("\(relativePath)/") else {
                continue
            }

            if directoryURLs.contains(url) {
                candidates.append(Self.directoryCandidate(
                    relativePath: relativePath,
                    directoryURL: url
                ))
            } else {
                candidates.append(Self.fileCandidate(
                    relativePath: relativePath,
                    fileURL: url,
                    fileName: url.lastPathComponent
                ))
            }
        }
        return Array(sortedFileSystemCandidates(candidates).prefix(rootSuggestionLimit))
    }

    private static func scanFilesWithRipgrep(rootURL: URL) async -> [TextBoxMentionCandidate]? {
        guard let executable = RipgrepExecutableResolver.resolve() else { return nil }

        var arguments = executable.prefixArguments + [
            "--files",
            "--color", "never",
            "--no-messages"
        ]
        // Apply the same skip list as the fallback enumerator. rg honors
        // .gitignore in a git repo, but in a non-git root it would otherwise
        // descend into node_modules/vendor/Pods/etc. and blow the file budget.
        for name in skippedDirectoryNames.sorted() {
            arguments.append("--glob")
            arguments.append("!\(name)")
        }
        for suffix in skippedPackageDirectorySuffixes {
            arguments.append("--iglob")
            arguments.append("!*\(suffix)")
        }
        let ripgrep = TextBoxMentionRipgrepProcess(
            executableURL: executable.url,
            arguments: arguments,
            currentDirectoryURL: rootURL
        )
        return await withTaskCancellationHandler {
            await scanFilesWithRunningRipgrep(rootURL: rootURL, ripgrep: ripgrep)
        } onCancel: {
            ripgrep.terminate()
        }
    }

    private static func scanFilesWithRunningRipgrep(
        rootURL: URL,
        ripgrep: TextBoxMentionRipgrepProcess
    ) async -> [TextBoxMentionCandidate]? {
        guard await BlockingFileSystem.run({ ripgrep.start() }) else { return nil }

        let directorySeed = await scanDirectoryCandidateSeed(rootURL: rootURL)
        var directoryCandidates = directorySeed.candidates
        var fileCandidates: [TextBoxMentionCandidate] = []
        var seenDirectoryRelativePaths = directorySeed.seenRelativePaths
        fileCandidates.reserveCapacity(min(maxIndexedFiles, 1024))

        func appendDirectoryCandidate(relativePath: String) {
            guard !relativePath.isEmpty,
                  directoryCandidates.count < maxIndexedDirectories,
                  seenDirectoryRelativePaths.insert(relativePath).inserted else {
                return
            }
            let directoryURL = rootURL
                .appendingPathComponent(relativePath, isDirectory: true)
                .standardizedFileURL
            directoryCandidates.append(Self.directoryCandidate(
                relativePath: relativePath,
                directoryURL: directoryURL
            ))
        }

        func appendDirectoryCandidates(containing relativePath: String) {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > 1 else { return }

            var currentPath = ""
            for component in components.dropLast() {
                let componentName = String(component)
                guard !shouldSkipIndexedDirectoryName(componentName) else { return }
                currentPath = currentPath.isEmpty ? componentName : "\(currentPath)/\(componentName)"
                appendDirectoryCandidate(relativePath: currentPath)
            }
        }

        func appendFileCandidate(relativePath: String) {
            guard !relativePath.isEmpty, fileCandidates.count < maxIndexedFiles else { return }
            appendDirectoryCandidates(containing: relativePath)
            let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
            let name = fileURL.lastPathComponent
            fileCandidates.append(Self.fileCandidate(
                relativePath: relativePath,
                fileURL: fileURL,
                fileName: name
            ))
        }

        // Blocking pipe reads and the process wait run on the dedicated queue, not the cooperative pool.
        let limit = maxIndexedFiles
        guard let output = await BlockingFileSystem.run({ ripgrep.collectLines(limit: limit) }) else {
            return nil
        }
        for relativePath in output.lines {
            appendFileCandidate(relativePath: relativePath)
        }
        guard output.reachedLimit || output.status == 0 || output.status == 1 else {
            return nil
        }

        return sortedFileSystemCandidates(directoryCandidates + fileCandidates)
    }

    private static func scanDirectoryCandidateSeed(
        rootURL: URL
    ) async -> (candidates: [TextBoxMentionCandidate], seenRelativePaths: Set<String>) {
        let rootPath = rootURL.standardizedFileURL.path
        let gitIgnoreProbe = TextBoxGitIgnoreProbe(rootURL: rootURL)
        let checksGitIgnore = await gitIgnoreProbe.isWorkTree()
        var candidates: [TextBoxMentionCandidate] = []
        var seenRelativePaths = Set<String>()
        candidates.reserveCapacity(min(maxIndexedDirectories, 256))

        var directoryQueue = await BlockingFileSystem.run { childDirectoryURLs(in: rootURL) }
        var queueIndex = 0

        while queueIndex < directoryQueue.count, candidates.count < maxIndexedDirectories {
            let batchEndIndex = min(directoryQueue.count, queueIndex + directorySeedBatchSize)
            let directoryBatch = Array(directoryQueue[queueIndex..<batchEndIndex])
            queueIndex = batchEndIndex

            let relativePaths = directoryBatch.map {
                Self.relativePath(for: $0.path, rootPath: rootPath)
            }
            let ignoredRelativePaths = checksGitIgnore
                ? await gitIgnoreProbe.ignoredRelativePaths(relativePaths)
                : []

            for standardizedURL in directoryBatch {
                let relativePath = Self.relativePath(for: standardizedURL.path, rootPath: rootPath)
                guard !relativePath.isEmpty,
                      !ignoredRelativePaths.contains(relativePath),
                      !ignoredRelativePaths.contains("\(relativePath)/") else {
                    continue
                }

                if seenRelativePaths.insert(relativePath).inserted {
                    candidates.append(Self.directoryCandidate(
                        relativePath: relativePath,
                        directoryURL: standardizedURL
                    ))
                    if candidates.count >= maxIndexedDirectories {
                        break
                    }
                }

                if Task.isCancelled { return (candidates, seenRelativePaths) }
                directoryQueue.append(contentsOf: await BlockingFileSystem.run {
                    childDirectoryURLs(in: standardizedURL)
                })
            }
        }

        return (candidates, seenRelativePaths)
    }

    private static func childDirectoryURLs(in directoryURL: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return children
            .map(\.standardizedFileURL)
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                    !shouldSkipIndexedDirectoryName($0.lastPathComponent)
            }
    }

    private static func directoryCandidate(relativePath: String, directoryURL: URL) -> TextBoxMentionCandidate {
        let normalizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let displayTitle = "@\(normalizedPath)/"
        let directoryName = directoryURL.lastPathComponent
        return TextBoxMentionCandidate(
            title: displayTitle,
            subtitle: displayPath(directoryURL.path),
            targetPath: directoryURL.path,
            systemImageName: "folder",
            searchKey: "\(normalizedPath) \(directoryName) folder directory".lowercased(),
            priority: directoryPriority(relativePath: normalizedPath)
        )
    }

    private static func fileCandidate(
        relativePath: String,
        fileURL: URL,
        fileName: String
    ) -> TextBoxMentionCandidate {
        TextBoxMentionCandidate(
            title: "@\(relativePath)",
            subtitle: displayPath(fileURL.path),
            targetPath: fileURL.path,
            systemImageName: "doc",
            searchKey: "\(relativePath) \(fileName)".lowercased(),
            priority: filePriority(relativePath: relativePath)
        )
    }

    private static func directoryPriority(relativePath: String) -> Int {
        let depth = max(relativePath.split(separator: "/").count, 1)
        return min((depth * 2) - 2, 40)
    }

    private static func filePriority(relativePath: String) -> Int {
        let depth = max(relativePath.split(separator: "/").count, 1)
        return min((depth * 2) - 1, 41)
    }

    private static func sortedFileSystemCandidates(
        _ candidates: [TextBoxMentionCandidate]
    ) -> [TextBoxMentionCandidate] {
        candidates.sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func scanSkillFiles(rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        var result: [URL] = []
        if fileManager.fileExists(atPath: rootURL.appendingPathComponent("SKILL.md").path) {
            result.append(rootURL.appendingPathComponent("SKILL.md"))
            return result
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return result }

        while let item = enumerator.nextObject() as? URL {
            let standardizedURL = item.standardizedFileURL
            let name = standardizedURL.lastPathComponent
            let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if shouldSkipIndexedDirectoryName(name) {
                    enumerator.skipDescendants()
                    continue
                }

                let skillFile = standardizedURL.appendingPathComponent("SKILL.md", isDirectory: false)
                if fileManager.fileExists(atPath: skillFile.path) {
                    result.append(skillFile.standardizedFileURL)
                    enumerator.skipDescendants()
                }
            } else if values?.isRegularFile == true, name == "SKILL.md" {
                result.append(standardizedURL)
            }

            if result.count >= maxIndexedSkills {
                break
            }
        }

        return result
    }

    private static func skillSearchRoots(rootDirectory: String?) -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []

        if let rootDirectory {
            var current = URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL
            while current.path != "/" {
                let skillsURL = current.appendingPathComponent("skills", isDirectory: true)
                if fileManager.fileExists(atPath: skillsURL.path) {
                    roots.append(skillsURL)
                }
                current.deleteLastPathComponent()
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".codex/skills", isDirectory: true))
        roots.append(home.appendingPathComponent(".codex/skills/.system", isDirectory: true))
        roots.append(home.appendingPathComponent(".agents/skills", isDirectory: true))
        roots.append(contentsOf: pluginSkillRoots(
            pluginCacheURL: home.appendingPathComponent(".codex/plugins/cache", isDirectory: true),
            fileManager: fileManager
        ))

        var seen = Set<String>()
        return roots
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.path).inserted }
    }

    private static func pluginSkillRoots(pluginCacheURL: URL, fileManager: FileManager) -> [URL] {
        guard let vendors = try? fileManager.contentsOfDirectory(
            at: pluginCacheURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var roots: [URL] = []
        for vendor in vendors where isDirectory(vendor, fileManager: fileManager) {
            guard let pluginNames = try? fileManager.contentsOfDirectory(
                at: vendor,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for pluginName in pluginNames where isDirectory(pluginName, fileManager: fileManager) {
                guard let versions = try? fileManager.contentsOfDirectory(
                    at: pluginName,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for version in versions where isDirectory(version, fileManager: fileManager) {
                    let skillsURL = version.appendingPathComponent("skills", isDirectory: true)
                    if isDirectory(skillsURL, fileManager: fileManager) {
                        roots.append(skillsURL)
                    }
                }
            }
        }
        return roots
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func shouldSkipIndexedDirectoryName(_ name: String) -> Bool {
        if skippedDirectoryNames.contains(name) {
            return true
        }
        let normalizedName = name.lowercased()
        return skippedPackageDirectorySuffixes.contains { suffix in
            normalizedName.hasSuffix(suffix.lowercased())
        }
    }

    private static func skillName(from skillURL: URL) -> String {
        guard let content = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return skillURL.deletingLastPathComponent().lastPathComponent
        }

        for line in content.split(separator: "\n", maxSplits: 32, omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("name:") else { continue }
            let name = String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return skillURL.deletingLastPathComponent().lastPathComponent
    }

    private static func skillSearchKey(skillName: String, skillURL: URL, rootURL: URL) -> String {
        let skillDirectory = skillURL.deletingLastPathComponent().standardizedFileURL
        let relativeSkillPath = relativePath(
            for: skillDirectory.path,
            rootPath: rootURL.standardizedFileURL.path
        )
        return "\(skillName) \(relativeSkillPath)".lowercased()
    }

    private static func normalizedDirectoryOffPool(_ path: String?) async -> String? {
        await BlockingFileSystem.run { normalizedDirectory(path) }
    }

    /// Existing directory that is safe to index, or nil (missing, or `/`/home/ancestor of home).
    private static func normalizedScannableDirectory(_ path: String?) async -> String? {
        await BlockingFileSystem.run {
            guard let directory = normalizedDirectory(path), !isUnscannableRoot(directory) else { return nil }
            return directory
        }
    }

    private nonisolated static func normalizedDirectory(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.path
    }

    private static func relativePath(for path: String, rootPath: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        let start = path.index(path.startIndex, offsetBy: rootPath.count)
        let relative = String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : relative
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}


/// Cancels registered scan tasks when released (the actor itself cannot cancel from `deinit`).
private final class TextBoxMentionScanTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<TextBoxMentionCandidateIndex, Never>] = []

    func add(_ task: Task<TextBoxMentionCandidateIndex, Never>) {
        lock.lock()
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
        lock.unlock()
    }

    deinit {
        for task in tasks { task.cancel() }
    }
}

private final class TextBoxMentionWillTerminateObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init() {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in TextBoxMentionRipgrepProcess.terminateAll() }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// One `rg --files` child. Reachable from cancellation, store teardown and app termination.
///
/// The child is wrapped in `perl -e 'alarm N; exec @ARGV'` (alarm survives exec) so that a SIGKILL
/// of the app cannot leave it running past `maxLifetimeSeconds`: macOS has no parent-death signal.
final class TextBoxMentionRipgrepProcess: @unchecked Sendable {
    private static let maxLifetimeSeconds = 120
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: TextBoxMentionRipgrepProcess] = [:]

    static func terminateAll() {
        registryLock.lock()
        let processes = Array(live.values)
        registryLock.unlock()
        for process in processes { process.terminate() }
    }

    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private let exited = DispatchSemaphore(value: 0)

    init(executableURL: URL, arguments: [String], currentDirectoryURL: URL) {
        let perl = "/usr/bin/perl"
        if FileManager.default.isExecutableFile(atPath: perl) {
            process.executableURL = URL(fileURLWithPath: perl)
            process.arguments = ["-e", "alarm \(Self.maxLifetimeSeconds); exec @ARGV", "--", executableURL.path] + arguments
        } else {
            process.executableURL = executableURL
            process.arguments = arguments
        }
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
    }

    /// Waits for the child without `Process.waitUntilExit`, which spins a run loop and never
    /// returns when the termination notification is lost (the child was already reaped by
    /// someone else). Falls back to a pid liveness probe. Returns nil when the exit status is
    /// unknown; the caller already has the complete pipe output at that point.
    private func waitForExit() -> Int32? {
        let pid = process.processIdentifier
        while exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            if kill(pid, 0) != 0, errno == ESRCH { return nil }
        }
        return process.terminationStatus
    }

    /// Blocking (fork/exec); call off the cooperative pool.
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            return false
        }
        started = true
        try? pipe.fileHandleForWriting.close()
        Self.registryLock.lock()
        Self.live[ObjectIdentifier(self)] = self
        Self.registryLock.unlock()
        return true
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let shouldKill = started && process.isRunning
        lock.unlock()
        if shouldKill { process.terminate() }
    }

    /// Blocking; reads up to `limit` non-empty lines, terminates the child at the limit, waits for exit.
    func collectLines(limit: Int) -> (lines: [String], reachedLimit: Bool, status: Int32)? {
        defer {
            try? pipe.fileHandleForReading.close()
            Self.registryLock.lock()
            Self.live[ObjectIdentifier(self)] = nil
            Self.registryLock.unlock()
        }
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var lines: [String] = []
        func take(_ data: Data) {
            if let text = String(data: data, encoding: .utf8), !text.isEmpty { lines.append(text) }
        }
        readLoop: while lines.count < limit {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 65536) } catch {
                terminate()
                _ = waitForExit()
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                take(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
                if lines.count >= limit { break readLoop }
            }
        }
        let reachedLimit = lines.count >= limit
        if reachedLimit {
            terminate()
        } else if !buffer.isEmpty {
            take(buffer)
        }
        // Unknown status after EOF means the child is gone and the listing is complete.
        let status = waitForExit() ?? 0
        return (lines, reachedLimit, status)
    }
}
