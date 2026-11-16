import Foundation

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--project") {
            SelfTest.project()
        } else if args.contains("--studio") {
            // First, because it has a --render option of its own.
            SelfTest.studio()
        } else if args.contains("--selftest-record") {
            SelfTest.record()
        } else if args.contains("--import") {
            SelfTest.importVideo()
        } else if args.contains("--transcribe") {
            SelfTest.transcribe()
        } else if args.contains("--render") {
            SelfTest.render()
        } else if args.contains("--notes") {
            SelfTest.notes()
        } else if args.contains("--remotion") {
            SelfTest.remotion()
        } else if args.contains("--storyboard") {
            SelfTest.storyboard()
        } else {
            TasjeelApp.main()
        }
    }
}
