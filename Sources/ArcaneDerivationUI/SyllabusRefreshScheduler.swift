import BackgroundTasks
import Foundation

enum SyllabusRefreshScheduler {
    static let identifier = "com.inf6.inf6.syllabus-refresh"
    private static let sourceURL = URL(string: "https://www.jdla.org/certificate/engineer/")!

    static func schedule(rootPath: String) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            recordSchedulingFailure(rootPath: rootPath, error: error)
        }
    }

    static func run(rootPath: String) async {
        defer { schedule(rootPath: rootPath) }
        guard !rootPath.isEmpty else { return }
        do {
            let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
            _ = try await SyllabusUpdateService(root: workspace).refresh(domain: "E資格", sourceURL: sourceURL)
        } catch {
            do {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                try SyllabusRepository(root: workspace).recordRefreshFailure(domain: "E資格", error: error)
            } catch {
                recordSchedulingFailure(rootPath: rootPath, error: error)
            }
        }
    }

    private static func recordSchedulingFailure(rootPath: String, error: Error) {
        guard !rootPath.isEmpty else { return }
        do {
            let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
            try SyllabusRepository(root: workspace).recordRefreshFailure(
                domain: "E資格",
                error: SchedulerError.persistence(error.localizedDescription)
            )
        } catch {
            print("シラバス更新状態を保存できません: \(error.localizedDescription)")
        }
    }

    private enum SchedulerError: LocalizedError {
        case persistence(String)

        var errorDescription: String? {
            switch self {
            case .persistence(let reason): return "シラバス更新状態を保存できません: \(reason)"
            }
        }
    }
}
