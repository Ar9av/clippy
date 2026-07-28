import ClippyCore
import Foundation

/// clippy-eval — offline-by-default regression harness for the tool-use
/// screen-intent path (ClippyTools + SystemPrompt), and an opt-in live suite
/// against the real Anthropic API.
///
/// Usage:
///   swift run clippy-eval --offline [--suite safety|intent|plan] [--report path.json]
///   ANTHROPIC_API_KEY=sk-... swift run clippy-eval --model claude-opus-4-5-20251101 [--report path.json]

struct CLIArguments {
    var suite: String?
    var offline = false
    var model = AnthropicClient.defaultModel
    var reportPath: String?

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--offline":
                offline = true
            case "--suite":
                index += 1
                if index < arguments.count { suite = arguments[index] }
            case "--model":
                index += 1
                if index < arguments.count { model = arguments[index] }
            case "--report":
                index += 1
                if index < arguments.count { reportPath = arguments[index] }
            default:
                break
            }
            index += 1
        }
    }
}

@main
struct ClippyEvalMain {
    static func main() async {
        let args = CLIArguments(Array(CommandLine.arguments.dropFirst()))
        var cases = EvalCase.loadAll()
        if let suite = args.suite {
            cases = cases.filter { $0.suite == suite }
        }

        print("clippy-eval — \(cases.count) case(s), mode: \(args.offline ? "offline" : "live"), prompt \(SystemPrompt.version)")

        do {
            let report = try await EvalRunner.run(cases: cases, model: args.model, offline: args.offline)
            for result in report.results {
                let mark = result.passed ? "PASS" : "FAIL"
                print("[\(mark)] \(result.suite)/\(result.id)\(result.detail.isEmpty ? "" : " — \(result.detail)")")
            }
            print("——")
            print("\(report.passCount)/\(report.totalCount) passed. Safety suite pass rate: \(Int(report.safetyPassRate * 100))%")

            if let reportPath = args.reportPath {
                let data = try JSONEncoder().encode(report)
                try data.write(to: URL(fileURLWithPath: reportPath))
                print("Report written to \(reportPath)")
            }

            let safetyFailed = report.results.contains { $0.suite == "safety" && !$0.passed }
            if safetyFailed || report.passCount < report.totalCount {
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("clippy-eval error: \(error)\n".utf8))
            exit(1)
        }
    }
}
