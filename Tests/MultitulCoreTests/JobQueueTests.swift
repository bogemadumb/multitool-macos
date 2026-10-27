import Testing
import Foundation
@testable import MultitulCore

private actor Gate {
    private var open = false
    func release() { open = true }
    func wait() async { while !open && !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) } }
}

private actor EventLog {
    private(set) var events: [String] = []
    func add(_ e: String) { events.append(e) }
}

@MainActor @Suite struct JobQueueTests {
    @Test func jobRunsAndSucceeds() async {
        let q = JobQueue()
        let id = q.enqueue(title: "A") { ctx in ctx.setProgress(0.5, detail: "half"); ctx.log("line"); return .success("done") }
        await q.waitUntilIdle()
        let j = q.job(id)
        #expect(j?.state == .succeeded && j?.result == "done" && j?.detail == "half" && j?.log == ["line"] && j?.progress == 0.5)
        #expect(!q.isBusy)
    }

    @Test func failureCarriesTheMessage() async {
        let q = JobQueue()
        let id = q.enqueue(title: "A") { _ in .failure("boom") }
        await q.waitUntilIdle()
        #expect(q.job(id)?.state == .failed("boom"))
        #expect(q.job(id)?.state.title == "Ошибка")
    }

    @Test func serialQueueRunsOneAtATime() async {
        let q = JobQueue(maxConcurrent: 1)
        let log = EventLog()
        let gate = Gate()
        let a = q.enqueue(title: "A") { _ in await log.add("a-start"); await gate.wait(); await log.add("a-end"); return .success("") }
        let b = q.enqueue(title: "B") { _ in await log.add("b-start"); return .success("") }
        #expect(q.job(a)?.state == .running && q.job(b)?.state == .queued)
        #expect(q.runningCount == 1 && q.queuedCount == 1)
        await gate.release()
        await q.waitUntilIdle()
        #expect(await log.events == ["a-start", "a-end", "b-start"])
        #expect(q.job(b)?.state == .succeeded)
    }

    @Test func parallelQueueStartsSeveral() async {
        let q = JobQueue(maxConcurrent: 2)
        let gate = Gate()
        let ids = (0..<3).map { i in q.enqueue(title: "J\(i)") { _ in await gate.wait(); return .success("") } }
        #expect(q.runningCount == 2 && q.queuedCount == 1)
        await gate.release()
        await q.waitUntilIdle()
        #expect(ids.allSatisfy { q.job($0)?.state == .succeeded })
    }

    @Test func cancelQueuedJobSkipsIt() async {
        let q = JobQueue()
        let gate = Gate()
        let ran = EventLog()
        _ = q.enqueue(title: "A") { _ in await gate.wait(); return .success("") }
        let b = q.enqueue(title: "B") { _ in await ran.add("b"); return .success("") }
        q.cancel(b)
        #expect(q.job(b)?.state == .cancelled)
        await gate.release()
        await q.waitUntilIdle()
        #expect(await ran.events.isEmpty)
    }

    @Test func cancelRunningJobStopsTheWork() async {
        let q = JobQueue()
        let started = Gate()
        let id = q.enqueue(title: "A") { _ in
            await started.release()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return .cancelled
        }
        await started.wait()
        q.cancel(id)
        await q.waitUntilIdle()
        #expect(q.job(id)?.state == .cancelled)
    }

    @Test func cancelWinsOverLateSuccess() async {
        let q = JobQueue()
        let started = Gate()
        let release = Gate()
        let id = q.enqueue(title: "A") { _ in await started.release(); await release.wait(); return .success("late") }
        await started.wait()
        q.cancel(id)
        await release.release()
        await q.waitUntilIdle()
        #expect(q.job(id)?.state == .cancelled && q.job(id)?.result == "")
    }

    @Test func cancelAllEmptiesTheQueue() async {
        let q = JobQueue()
        let ids = (0..<3).map { i in
            q.enqueue(title: "J\(i)") { _ in
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
                return .cancelled
            }
        }
        q.cancelAll()
        await q.waitUntilIdle()
        #expect(ids.allSatisfy { q.job($0)?.state == .cancelled })
    }

    @Test func nextJobStartsAfterACancelledOne() async {
        let q = JobQueue()
        let first = q.enqueue(title: "A") { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return .cancelled
        }
        let second = q.enqueue(title: "B") { _ in .success("ok") }
        q.cancel(first)
        await q.waitUntilIdle()
        #expect(q.job(first)?.state == .cancelled && q.job(second)?.state == .succeeded)
    }

    @Test func finishCallbackSeesEveryEnd() async {
        let q = JobQueue()
        var seen: [JobState] = []
        q.onFinish = { seen.append($0.state) }
        _ = q.enqueue(title: "A") { _ in .success("") }
        _ = q.enqueue(title: "B") { _ in .failure("x") }
        await q.waitUntilIdle()
        #expect(seen == [.succeeded, .failed("x")])
    }

    @Test func clearFinishedKeepsActiveJobs() async {
        let q = JobQueue()
        let gate = Gate()
        _ = q.enqueue(title: "A") { _ in .success("") }
        let b = q.enqueue(title: "B") { _ in await gate.wait(); return .success("") }
        for _ in 0..<200 where q.jobs.first?.state != .succeeded { try? await Task.sleep(nanoseconds: 2_000_000) }
        q.clearFinished()
        #expect(q.jobs.map(\.id) == [b])
        await gate.release()
        await q.waitUntilIdle()
    }

    @Test func historyIsTrimmed() async {
        let q = JobQueue(maxConcurrent: 1, historyLimit: 3)
        for i in 0..<6 { _ = q.enqueue(title: "J\(i)") { _ in .success("") } }
        await q.waitUntilIdle()
        _ = q.enqueue(title: "last") { _ in .success("") }
        await q.waitUntilIdle()
        #expect(q.jobs.count <= 4)
        #expect(q.jobs.last?.title == "last")
    }

    @Test func progressIsClampedAndLogIsBounded() async {
        let q = JobQueue()
        let id = q.enqueue(title: "A") { ctx in
            ctx.setProgress(7)
            for i in 0..<500 { ctx.log("l\(i)") }
            return .success("")
        }
        await q.waitUntilIdle()
        #expect(q.job(id)?.progress == 1 && q.job(id)?.log.count == 200 && q.job(id)?.log.last == "l499")
    }

    @Test func waitingOnAnIdleQueueReturnsAtOnce() async {
        let q = JobQueue()
        await q.waitUntilIdle()
        #expect(q.jobs.isEmpty)
    }

    @Test func idsAreSequential() {
        let q = JobQueue()
        let a = q.enqueue(title: "A") { _ in .success("") }
        let b = q.enqueue(title: "B") { _ in .success("") }
        #expect(b == a + 1)
        q.cancelAll()
    }
}
