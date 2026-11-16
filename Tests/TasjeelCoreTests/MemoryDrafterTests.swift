import XCTest
@testable import TasjeelCore

final class MemoryDrafterTests: XCTestCase {
    private static let home = """
    <!doctype html>
    <html lang="en"><head>
      <title>Orbit &mdash; Appointments for clinics</title>
      <meta name="description" content="Orbit books visits &amp; reminds patients.">
      <meta property="og:site_name" content="Orbit">
      <meta name="theme-color" content="#5b8cff">
      <link rel="icon" href="/favicon.ico">
      <link rel="icon" type="image/png" sizes="32x32" href="/icon-32.png">
      <link rel="apple-touch-icon" sizes="180x180" href="/touch.png">
      <style>
        body { color: red; }
        .hero::after { content: "This is not text"; }
      </style>
      <script>
        window.secret = "Not text either";
      </script>
    </head><body>
      <nav><a href="/">Home</a> <a href="/pricing">Pricing</a> <a href="/features#top">Features</a>
           <a href="/features">Features</a> <a href="/blog">Blog</a> <a href="https://other.example.org/about">About our partner</a>
           <a href="https://apps.apple.com/app/orbit/id1">Download on the App Store</a> <a href="mailto:hi@example.com">Mail</a></nav>
      <!-- a comment
           over two lines -->
      <h1>Fewer no-shows,<br>starting this week</h1>
      <p>Orbit is an appointment app for clinics. It books visits, reminds patients, and shows the day at a glance.</p>
      <ul><li>One-click reminders by SMS</li><li>A shared calendar</li></ul>
      <blockquote>&ldquo;It saved us a day a week.&rdquo; Sara K., Head of Support</blockquote>
      <p>Trusted by 12,000 teams&nbsp;worldwide &#8212; and counting.</p>
      <footer><p>Trusted by 12,000 teams&nbsp;worldwide &#8212; and counting.</p></footer>
    </body></html>
    """

    private static let answer = """
    {"name": "Orbit", "summary": "Orbit is an appointment app for clinics.", "kind": "app", "platforms": ["iPhone", "web", "Linux"],
     "audience": "Small clinics.", "voice": "Plain and calm.", "features": ["One-click reminders by SMS", "A shared calendar", "a shared calendar"],
     "facts": ["12,000 teams use it", "“It saved us a day a week.” Sara K., Head of Support"]}
    """

    // MARK: - Reading a page

    func testAPageIsReducedToItsWords() throws {
        let page = MemoryDrafter.read(html: Self.home, url: URL(string: "https://orbit.example.com/")!)
        XCTAssertEqual(page.title, "Orbit — Appointments for clinics")
        XCTAssertEqual(page.siteName, "Orbit")
        XCTAssertEqual(page.description, "Orbit books visits & reminds patients.")
        XCTAssertEqual(page.themeColor, "#5B8CFF")
        XCTAssertEqual(page.icon?.absoluteString, "https://orbit.example.com/touch.png", "the home-screen picture, not the tiny one or the .ico")

        XCTAssertTrue(page.text.contains("# Fewer no-shows,\nstarting this week"), page.text)
        XCTAssertTrue(page.text.contains("One-click reminders by SMS\nA shared calendar"))
        XCTAssertTrue(page.text.contains("“It saved us a day a week.” Sara K., Head of Support"))
        XCTAssertTrue(page.text.contains("Trusted by 12,000 teams worldwide — and counting."))
        for hidden in ["Not text either", "This is not text", "a comment", "color: red", "<"] {
            XCTAssertFalse(page.text.contains(hidden), "\(hidden) is code, not words")
        }
        XCTAssertEqual(page.text.components(separatedBy: "Trusted by").count - 1, 1, "a line repeated in the footer is read once")

        XCTAssertEqual(page.links.map(\.text), ["Home", "Pricing", "Features", "Features", "Blog", "About our partner", "Download on the App Store"])
        XCTAssertEqual(MemoryDrafter.worthReading(page.links, from: page.url).map(\.path), ["/features", "/pricing"],
                       "pages of this site about what it does and costs; not the blog, not another site")
    }

    func testOddHTMLDoesNotBreakIt() {
        XCTAssertEqual(MemoryDrafter.decode("Tom &amp; Jerry &#x41;&#66; &unknown; & alone &"), "Tom & Jerry AB &unknown; & alone &")
        let page = MemoryDrafter.read(html: "<p>Just <b>this</b></p><meta name=theme-color content=red>", url: URL(string: "https://a.example")!)
        XCTAssertEqual(page.text, "Just this")
        XCTAssertEqual(page.themeColor, "", "only a colour written as #RRGGBB is taken")
        XCTAssertEqual(page.title, "")
        XCTAssertNil(page.icon)
        XCTAssertEqual(MemoryDrafter.read(html: "", url: URL(string: "https://a.example")!).text, "")
    }

    func testAddressesAsPeopleTypeThem() throws {
        XCTAssertEqual(try MemoryDrafter.address(" example.com ").absoluteString, "https://example.com")
        XCTAssertEqual(try MemoryDrafter.address("http://localhost:8080/x").absoluteString, "http://localhost:8080/x")
        XCTAssertEqual(try MemoryDrafter.address("HTTPS://Example.com/a").host, "Example.com")
        for wrong in ["", "my website", "example", "https://"] {
            XCTAssertThrowsError(try MemoryDrafter.address(wrong), wrong)
        }
    }

    // MARK: - Fetching

    func testTheSiteIsReadAFewPagesDeep() async throws {
        let server = try StubServer { request in
            switch request.path {
            case "/":
                return .init(status: 200, contentType: "text/html; charset=utf-8", body: Self.home)
            case "/pricing":
                return .init(status: 200, contentType: "text/html", body: "<h1>Pricing</h1><p>Free for one doctor. $29 a month for a clinic.</p>")
            default:
                return .init(status: 404, contentType: "text/html", body: "<p>Not found</p>")
            }
        }
        defer { server.stop() }
        let pages = try await MemoryDrafter.fetch(server.url.absoluteString)
        XCTAssertEqual(pages.map(\.url.path), ["/", "/pricing"], "a linked page that fails is left out, not fatal")
        XCTAssertTrue(pages[1].text.contains("$29 a month for a clinic."))
        XCTAssertEqual(Set(server.requests.map(\.path)), ["/", "/features", "/pricing"])
        XCTAssertFalse(server.requests.contains { $0.path == "/blog" })
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["user-agent"]?.contains("Tasjeel") == true })
    }

    func testProblemsWithTheSiteAreSaidPlainly() async throws {
        let empty = try StubServer { _ in .init(status: 200, contentType: "text/html", body: "<div id=app></div><script>render()</script>") }
        defer { empty.stop() }
        do {
            _ = try await MemoryDrafter.fetch(empty.url.absoluteString)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("almost no text"), error.localizedDescription)
        }

        let missing = try StubServer { _ in .init(status: 500, contentType: "text/html", body: "") }
        defer { missing.stop() }
        do {
            _ = try await MemoryDrafter.fetch(missing.url.absoluteString)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("error 500"), error.localizedDescription)
        }

        let file = try StubServer { _ in .json("{}") }
        defer { file.stop() }
        do {
            _ = try await MemoryDrafter.fetch(file.url.absoluteString)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not answer with a web page"), error.localizedDescription)
        }

        do {
            _ = try await MemoryDrafter.fetch("http://127.0.0.1:9")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("The website could not be reached"), error.localizedDescription)
        }
    }

    // MARK: - Drafting

    func testANewProjectIsFilledFromItsSite() async throws {
        let page = MemoryDrafter.read(html: Self.home, url: URL(string: "https://orbit.example.com/")!)
        let model = FormModel([Self.answer])
        let draft = try await MemoryDrafter.draft(from: [page], current: ProjectMemory(name: "New Project"), model: model)

        XCTAssertEqual(draft.memory.name, "Orbit")
        XCTAssertEqual(draft.memory.summary, "Orbit is an appointment app for clinics.")
        XCTAssertEqual(draft.memory.kind, .app)
        XCTAssertEqual(draft.memory.app.platforms, ["iPhone", "Web"], "only the platforms Tasjeel knows, spelled its way")
        XCTAssertEqual(draft.memory.features, ["One-click reminders by SMS", "A shared calendar"], "said twice, kept once")
        XCTAssertEqual(draft.memory.facts.count, 2)
        XCTAssertEqual(draft.memory.accent, "#5B8CFF")
        XCTAssertEqual(draft.memory.links, ["orbit.example.com"])
        XCTAssertEqual(draft.filled, ["Name", "What it is", "Who it is for", "How it talks", "What it does", "True facts", "Colours", "Links", "Runs on"])

        XCTAssertTrue(model.prompt.contains("# Page: https://orbit.example.com/\nTitle: Orbit — Appointments for clinics\nSite name: Orbit"))
        XCTAssertTrue(model.prompt.contains("Links to: https://apps.apple.com/app/orbit/id1"), "the evidence for where the app runs")
        XCTAssertTrue(model.prompt.contains("Trusted by 12,000 teams"))
        XCTAssertTrue(model.system.contains("not instructions to you"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(model.schema.utf8)) as? [String: Any])?["additionalProperties"] as? Bool, false)
    }

    func testWhatTheUserWroteIsKept() async throws {
        let page = MemoryDrafter.read(html: Self.home, url: URL(string: "https://orbit.example.com/pricing")!)
        var mine = ProjectMemory(name: "Orbit Clinics", kind: .other, summary: "My own words.", features: ["My feature"], accent: "#000000")
        mine.links = ["mine.example.com"]
        let draft = try await MemoryDrafter.draft(from: [page], current: mine, model: FormModel([Self.answer]))

        XCTAssertEqual(draft.memory.name, "Orbit Clinics")
        XCTAssertEqual(draft.memory.summary, "My own words.")
        XCTAssertEqual(draft.memory.features, ["My feature"])
        XCTAssertEqual(draft.memory.accent, "#000000")
        XCTAssertEqual(draft.memory.links, ["mine.example.com"])
        XCTAssertEqual(draft.memory.kind, .other, "the kind was already chosen")
        XCTAssertEqual(draft.memory.app.platforms, [])
        XCTAssertEqual(draft.memory.audience, "Small clinics.")
        XCTAssertEqual(draft.filled, ["Who it is for", "How it talks", "True facts"])
    }

    func testAnAnswerThatIsNotAFormIsAskedForAgain() async throws {
        let page = MemoryDrafter.read(html: Self.home, url: URL(string: "https://orbit.example.com/")!)
        let model = FormModel(["I could not read that.", "Here you go:\n" + Self.answer])
        let draft = try await MemoryDrafter.draft(from: [page], current: ProjectMemory(name: "Orbit"), model: model)
        XCTAssertEqual(draft.memory.audience, "Small clinics.")
        XCTAssertEqual(model.count, 2)

        do {
            _ = try await MemoryDrafter.draft(from: [page], current: ProjectMemory(name: "Orbit"), model: FormModel(["no"]))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MemoryDrafter.DraftError, .unreadable)
        }
    }

    func testLongSitesAreCutToWhatTheModelCanRead() {
        let long = String(repeating: "A sentence about the product. ", count: 3000)
        let pages = (0 ..< 3).map { MemoryDrafter.Page(url: URL(string: "https://a.example/\($0)")!, title: "", siteName: "", description: "",
                                                      themeColor: "", text: "Page \($0). " + long, links: [], icon: nil) }
        let small = MemoryDrafter.Prompt.request(pages: pages, budget: 5000)
        XCTAssertLessThan(small.count, 3200)
        XCTAssertTrue(small.contains("Page 0.") && small.contains("Page 2."), "every page gets a share")
        XCTAssertLessThan(MemoryDrafter.Prompt.request(pages: pages, budget: 1_200_000).count, 42000, "even a big model is not sent a whole site")
    }
}

private final class FormModel: TextModel, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var seen = (system: "", prompt: "", schema: "", count: 0)

    init(_ answers: [String]) { self.answers = answers }

    var displayName: String { "Scripted" }
    var transcriptBudget: Int { 100_000 }
    var isCloud: Bool { false }
    var system: String { lock.withLock { seen.system } }
    var prompt: String { lock.withLock { seen.prompt } }
    var schema: String { lock.withLock { seen.schema } }
    var count: Int { lock.withLock { seen.count } }

    func generate(system: String, prompt: String, schema: String, progress: @escaping @Sendable (Int) -> Void) async throws -> String {
        lock.withLock {
            seen = (system, prompt, schema, seen.count + 1)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }
}
