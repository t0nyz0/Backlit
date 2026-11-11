import XCTest
@testable import Backlit
final class FadeCompletionTests:XCTestCase {
    func directory() throws -> URL {
        let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:d)}
        return d
    }
    func prepare(_ s:FadeRecoveryStore) throws -> UUID {
        try s.prepare(parentPID:1,context:.init(lidClosed:false,sleeping:false,locked:false,generation:1),keyboards:[13:2])
    }
    func testParentAndHelperFinalizationAreIdempotentOnlyWithReceipt() throws {
        let s=FadeRecoveryStore(directory:try directory()),t=try prepare(s);var calls=0
        try s.recover(token:t) {_ in calls+=1}
        try s.recover(token:t) {_ in calls+=1}
        XCTAssertEqual(calls,1);XCTAssertTrue(s.completed(token:t))
        XCTAssertThrowsError(try s.recover(token:UUID()) {_ in XCTFail("Wrong owner")})
    }
    func testMissingJournalWithoutProofIsNotSuccess() throws {
        let s=FadeRecoveryStore(directory:try directory())
        XCTAssertThrowsError(try s.recover(token:UUID()) {_ in XCTFail("No journal")})
    }
    func testReceiptWriteFailureRetainsRevokedJournal() throws {
        let s=FadeRecoveryStore(directory:try directory(),receiptWriter:{_,_ in throw NSError(domain:"write",code:1)})
        let t=try prepare(s)
        XCTAssertThrowsError(try s.recover(token:t) {_ in})
        XCTAssertFalse(try s.read().effectsAllowed);XCTAssertFalse(s.completed(token:t))
    }
    func testDeletionFailureRetriesWithoutRepeatingVerifiedHardwareRestore() throws {
        let d=try directory();var removals=0,restores=0
        let s=FadeRecoveryStore(directory:d,journalRemover:{url in
            removals+=1;if removals==1 {throw NSError(domain:"delete",code:1)}
            try FileManager.default.removeItem(at:url)
        })
        let t=try prepare(s)
        XCTAssertThrowsError(try s.recover(token:t) {_ in restores+=1})
        XCTAssertTrue(s.completed(token:t));XCTAssertFalse(try s.read().effectsAllowed)
        try s.recover(token:t) {_ in restores+=1}
        XCTAssertEqual(restores,1);XCTAssertFalse(FileManager.default.fileExists(atPath:s.url.path))
    }
    func testOldReceiptNeverDeletesNewOwnerJournal() throws {
        let s=FadeRecoveryStore(directory:try directory()),old=try prepare(s)
        try s.recover(token:old) {_ in}
        let new=try prepare(s)
        XCTAssertThrowsError(try s.recover(token:old) {_ in XCTFail("Old owner")})
        XCTAssertEqual(try s.read().token,new)
    }
}
