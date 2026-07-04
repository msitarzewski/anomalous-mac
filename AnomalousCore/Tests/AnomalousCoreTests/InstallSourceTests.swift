import Testing
@testable import AnomalousCore

@Suite("install source — inferred from path, path stays local")
struct InstallSourceTests {
    @Test("homebrew paths (Apple Silicon and Intel)")
    func homebrew() {
        #expect(InstallSource.classify(path: "/opt/homebrew/opt/mysql/bin/mysqld") == .homebrew)
        #expect(InstallSource.classify(path: "/usr/local/Cellar/redis/7.2/bin/redis-server") == .homebrew)
        #expect(InstallSource.classify(path: "/opt/homebrew/bin/ollama") == .homebrew)
    }

    @Test("macports")
    func macports() {
        #expect(InstallSource.classify(path: "/opt/local/bin/postgres") == .macports)
    }

    @Test("apple system daemons")
    func system() {
        #expect(InstallSource.classify(path: "/usr/libexec/dasd") == .appleSystem)
        #expect(InstallSource.classify(path: "/System/Library/CoreServices/WindowServer") == .appleSystem)
        #expect(InstallSource.classify(path: "/usr/sbin/bluetoothd") == .appleSystem)
    }

    @Test("ecosystems: docker, npm, python")
    func ecosystems() {
        #expect(InstallSource.classify(path: "/Users/x/proj/node_modules/.bin/webpack") == .npm)
        #expect(InstallSource.classify(path: "/Users/x/.venv/bin/python3.12") == .python)
        #expect(InstallSource.classify(path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend") == .docker)
    }

    @Test("ordinary mac app vs unknown")
    func apps() {
        #expect(InstallSource.classify(path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") == .userApplication)
        #expect(InstallSource.classify(path: "") == .other)
        #expect(InstallSource.classify(path: "/some/weird/place/thing") == .other)
    }

    @Test("homebrew mysqld carries a lifecycle hint, system daemons don't")
    func lifecycleHints() {
        #expect(InstallSource.homebrew.lifecycleHint?.contains("brew services") == true)
        #expect(InstallSource.docker.lifecycleHint?.contains("docker stop") == true)
        #expect(InstallSource.appleSystem.lifecycleHint == nil)
    }
}
