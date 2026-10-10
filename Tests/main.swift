// Parser check, no network or Keychain. Run: ./Tests/check.sh
import Foundation

let claude = try UsageFetcher.parseClaude(Data("""
{"five_hour": null,
 "seven_day": {"utilization": 42, "resets_at": "2026-10-12T08:00:00.123456+00:00"},
 "seven_day_sonnet": {"utilization": 7.5, "resets_at": null}}
""".utf8))
precondition(claude.map(\.title) == ["Weekly", "Sonnet"])
precondition(claude[0].percentLeft == 58 && claude[0].resetsAt != nil)
precondition(claude[1].usedPercent == 7.5 && claude[1].resetsAt == nil)

let org = try UsageFetcher.parseClaudeOrganization(Data("""
[{"uuid": "api-only", "capabilities": ["api"]}, {"uuid": "chat-org", "capabilities": ["chat", "claude_pro"]}]
""".utf8))
precondition(org == "chat-org")

let codex = try UsageFetcher.parseCodex(Data("""
{"plan_type": "plus", "rate_limit": {
  "primary_window": {"used_percent": 12, "reset_at": 1790000000, "limit_window_seconds": 18000},
  "secondary_window": {"used_percent": 130, "reset_at": 1790500000, "limit_window_seconds": 604800}}}
""".utf8))
precondition(codex.map(\.title) == ["Session", "Weekly"])
precondition(codex[0].percentLeft == 88 && codex[1].percentLeft == 0)
precondition((try? UsageFetcher.parseCodex(Data("<html>".utf8))) == nil)
let callback = "GET /auth/callback?code=abc%2B1&state=s1 HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"
func callbackCode(_ request: String, state: String) -> Result<String?, Error> {
    Result { try UsageFetcher.codexCallbackCode(request: request, state: state) }
}
precondition(try! callbackCode(callback, state: "s1").get() == "abc+1")
if case .success = callbackCode(callback, state: "other") { preconditionFailure("state mismatch must throw") }
precondition(try! callbackCode("GET /favicon.ico HTTP/1.1\r\n\r\n", state: "s1").get() == nil)
precondition(try! callbackCode("", state: "s1").get() == nil)
precondition(UsageFetcher.formEncode(["b": "x y+/", "a": "1"]) == "a=1&b=x%20y%2B%2F")
let now = Date(timeIntervalSince1970: 1_790_000_000)
let go = try UsageFetcher.parseOpenCodeGo(Data("""
{"usage": {"rolling": {"percent": 0.5, "resetInSec": 3600},
           "weekly": {"percent": 40, "resetAt": "2026-10-12T08:00:00Z"}}}
""".utf8), now: now)
precondition(go.map(\.title) == ["5-hour", "Weekly"])
precondition(go[0].usedPercent == 0.5 && go[0].resetsAt == now.addingTimeInterval(3600))
precondition(go[1].percentLeft == 60 && go[1].resetsAt != nil)
precondition((try? UsageFetcher.parseOpenCodeGo(Data("{}".utf8))) == nil)
print("ok")
