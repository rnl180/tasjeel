import Foundation

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest-record") {
            SelfTest.record()
        } else if args.contains("--import") {
            SelfTest.importVideo()
        } else if args.contains("--transcribe") {
            SelfTest.transcribe()
        } else {
            TasjeelApp.main()
        }
    }
}
