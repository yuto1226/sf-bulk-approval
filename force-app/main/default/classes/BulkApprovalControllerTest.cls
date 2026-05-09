/**
 * Tests for BulkApprovalController.
 *
 * The org running these tests must have an active approval process on
 * Opportunity for Approval.process() to succeed end-to-end. The tests guard
 * against the no-process configuration: when Approval.process() fails because
 * no process exists, the controller surfaces the failure as a BulkResult, and
 * we still assert on the structural shape (per-record entries, ordering,
 * ownership filters) which is valid either way.
 */
@IsTest
private class BulkApprovalControllerTest {

    private static User createTestUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(DateTime.now().getTime());
        User u = new User(
            FirstName = 'Bulk',
            LastName = 'Tester',
            Alias = 'bulkt',
            Email = 'bulk.tester+' + unique + '@example.invalid',
            Username = 'bulk.tester+' + unique + '@example.invalid.test',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    private static List<Opportunity> createOpportunities(Id ownerId, Integer count) {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(new Opportunity(
                Name = 'Bulk Opp ' + i,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30 + i),
                Amount = 1000 + i,
                OwnerId = ownerId
            ));
        }
        insert opps;
        return opps;
    }

    @IsTest
    static void getApprovalEnabledObjects_returnsList() {
        Test.startTest();
        List<BulkApprovalController.ApprovalObject> objs =
            BulkApprovalController.getApprovalEnabledObjects();
        Test.stopTest();

        // The org may have no approval processes configured; we only assert
        // that the call succeeds and returns a non-null list.
        System.assertNotEquals(null, objs);
    }

    @IsTest
    static void getSubmittableRecords_blankObjectThrows() {
        Test.startTest();
        Boolean threw = false;
        try {
            BulkApprovalController.getSubmittableRecords('', 10);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Blank objectApiName should throw');
    }

    @IsTest
    static void getSubmittableRecords_unknownObjectThrows() {
        Test.startTest();
        Boolean threw = false;
        try {
            BulkApprovalController.getSubmittableRecords('NotARealObject__c', 10);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Unknown objectApiName should throw');
    }

    @IsTest
    static void getSubmittableRecords_returnsOnlyOwnedRecords() {
        User testUser = createTestUser();
        List<Opportunity> mine;
        List<Opportunity> theirs;
        System.runAs(testUser) {
            mine = createOpportunities(testUser.Id, 3);
        }
        theirs = createOpportunities(UserInfo.getUserId(), 2);

        Test.startTest();
        BulkApprovalController.SubmittableData data;
        System.runAs(testUser) {
            data = BulkApprovalController.getSubmittableRecords('Opportunity', 50);
        }
        Test.stopTest();

        System.assertEquals('Opportunity', data.objectApiName);
        System.assertEquals(true, data.hasOwner);
        Set<Id> returnedIds = new Set<Id>();
        for (BulkApprovalController.RecordRow r : data.rows) {
            returnedIds.add(r.id);
        }
        for (Opportunity o : mine) {
            System.assert(returnedIds.contains(o.Id),
                'Owned opportunity should appear: ' + o.Id);
        }
        for (Opportunity o : theirs) {
            System.assert(!returnedIds.contains(o.Id),
                'Other-owned opportunity should not appear: ' + o.Id);
        }
    }

    @IsTest
    static void getSubmittableRecords_normalizesMaxRows() {
        User testUser = createTestUser();
        System.runAs(testUser) {
            createOpportunities(testUser.Id, 5);
        }

        Test.startTest();
        BulkApprovalController.SubmittableData none;
        BulkApprovalController.SubmittableData defaulted;
        System.runAs(testUser) {
            defaulted = BulkApprovalController.getSubmittableRecords('Opportunity', null);
            none = BulkApprovalController.getSubmittableRecords('Opportunity', 0);
        }
        Test.stopTest();

        System.assertEquals(5, defaulted.rows.size());
        System.assertEquals(5, none.rows.size());
    }

    @IsTest
    static void submitForApproval_emptyInputReturnsEmpty() {
        Test.startTest();
        List<BulkApprovalController.BulkResult> r1 =
            BulkApprovalController.submitForApproval(null, 'x');
        List<BulkApprovalController.BulkResult> r2 =
            BulkApprovalController.submitForApproval(new List<Id>(), 'x');
        Test.stopTest();

        System.assertEquals(0, r1.size());
        System.assertEquals(0, r2.size());
    }

    @IsTest
    static void submitForApproval_returnsResultPerRecord() {
        User testUser = createTestUser();
        List<Opportunity> opps;
        System.runAs(testUser) {
            opps = createOpportunities(testUser.Id, 2);
        }
        List<Id> ids = new List<Id>{ opps[0].Id, opps[1].Id };

        Test.startTest();
        List<BulkApprovalController.BulkResult> results;
        System.runAs(testUser) {
            results = BulkApprovalController.submitForApproval(ids, 'please review');
        }
        Test.stopTest();

        System.assertEquals(2, results.size(), 'one result per input id');
        System.assertEquals(opps[0].Id, results[0].recordId);
        System.assertEquals(opps[1].Id, results[1].recordId);
        for (BulkApprovalController.BulkResult r : results) {
            if (!r.success) {
                System.assertNotEquals(null, r.message,
                    'Failed submissions should include an error message');
            }
        }
    }

    @IsTest
    static void getMyPendingApprovals_runsWithoutError() {
        Test.startTest();
        List<BulkApprovalController.PendingApprovalRow> all =
            BulkApprovalController.getMyPendingApprovals(null);
        List<BulkApprovalController.PendingApprovalRow> filtered =
            BulkApprovalController.getMyPendingApprovals('Opportunity');
        Test.stopTest();

        System.assertNotEquals(null, all);
        System.assertNotEquals(null, filtered);
    }

    @IsTest
    static void processWorkitems_emptyInputReturnsEmpty() {
        Test.startTest();
        List<BulkApprovalController.BulkResult> r1 =
            BulkApprovalController.processWorkitems(null, 'Approve', 'ok');
        List<BulkApprovalController.BulkResult> r2 =
            BulkApprovalController.processWorkitems(new List<Id>(), 'Reject', 'no');
        Test.stopTest();

        System.assertEquals(0, r1.size());
        System.assertEquals(0, r2.size());
    }

    @IsTest
    static void processWorkitems_invalidActionThrows() {
        List<Id> fakeIds = new List<Id>{ UserInfo.getUserId() };
        Test.startTest();
        Boolean threw = false;
        try {
            BulkApprovalController.processWorkitems(fakeIds, 'Foo', 'bar');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Invalid action should throw AuraHandledException');
    }

    @IsTest
    static void processWorkitems_unknownIdReturnsFailure() {
        Id fakeWorkitemId = '04i000000000000AAA';
        List<Id> ids = new List<Id>{ fakeWorkitemId };

        Test.startTest();
        List<BulkApprovalController.BulkResult> results =
            BulkApprovalController.processWorkitems(ids, 'Approve', 'ok');
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(fakeWorkitemId, results[0].recordId);
        System.assertEquals(false, results[0].success);
        System.assertNotEquals(null, results[0].message);
    }

    @IsTest
    static void bulkResult_constructorSetsFields() {
        Id someId = UserInfo.getUserId();
        BulkApprovalController.BulkResult ok = new BulkApprovalController.BulkResult(someId, true, null);
        BulkApprovalController.BulkResult ng = new BulkApprovalController.BulkResult(someId, false, 'oops');

        System.assertEquals(someId, ok.recordId);
        System.assertEquals(true, ok.success);
        System.assertEquals(null, ok.message);
        System.assertEquals(false, ng.success);
        System.assertEquals('oops', ng.message);
    }

    @IsTest
    static void approvalObject_constructorSetsFields() {
        BulkApprovalController.ApprovalObject ao =
            new BulkApprovalController.ApprovalObject('Account', '取引先');
        System.assertEquals('Account', ao.apiName);
        System.assertEquals('取引先', ao.label);
    }
}
