/**
 * Apex controller for the bulk approval LWCs.
 *
 * Exposes AuraEnabled methods for:
 *   - listing the running user's submittable Opportunities,
 *   - listing pending approval workitems assigned to the running user,
 *   - submitting Opportunities for approval in bulk,
 *   - approving / rejecting workitems in bulk.
 *
 * Approval calls go through Approval.process(...) with allOrNone=false so that
 * partial success is preserved and per-record errors can be returned to the UI.
 */
public with sharing class BulkApprovalController {

    private static final Integer DEFAULT_MAX_ROWS = 200;
    private static final Integer ABSOLUTE_MAX_ROWS = 2000;

    /** Per-record result returned to the LWC. */
    public class BulkResult {
        @AuraEnabled public Id recordId;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;

        public BulkResult(Id recordId, Boolean success, String message) {
            this.recordId = recordId;
            this.success = success;
            this.message = message;
        }
    }

    /** Row shown on the bulk submit screen. */
    public class SubmittableOpportunity {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String accountName;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public String ownerName;
    }

    /** Row shown on the bulk approval screen. */
    public class PendingApprovalRow {
        @AuraEnabled public Id workitemId;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String submitterName;
        @AuraEnabled public Datetime submittedDate;
    }

    /**
     * Returns Opportunities owned by the running user that are not currently in
     * an in-flight approval process. "In-flight" is defined as having a
     * ProcessInstance whose Status is 'Pending'.
     */
    @AuraEnabled(cacheable=true)
    public static List<SubmittableOpportunity> getSubmittableOpportunities(Integer maxRows) {
        Integer limitRows = normalizeMaxRows(maxRows);
        Id runningUserId = UserInfo.getUserId();

        Set<Id> pendingOppIds = new Set<Id>();
        for (ProcessInstance pi : [
            SELECT TargetObjectId
            FROM ProcessInstance
            WHERE Status = 'Pending'
              AND TargetObject.Type = 'Opportunity'
            LIMIT 50000
        ]) {
            pendingOppIds.add(pi.TargetObjectId);
        }

        List<Opportunity> opps = [
            SELECT Id, Name, StageName, Amount, CloseDate,
                   Account.Name, Owner.Name
            FROM Opportunity
            WHERE OwnerId = :runningUserId
              AND Id NOT IN :pendingOppIds
            ORDER BY CloseDate ASC NULLS LAST, Name ASC
            LIMIT :limitRows
        ];

        List<SubmittableOpportunity> rows = new List<SubmittableOpportunity>();
        for (Opportunity o : opps) {
            SubmittableOpportunity row = new SubmittableOpportunity();
            row.id = o.Id;
            row.name = o.Name;
            row.accountName = o.Account != null ? o.Account.Name : null;
            row.stageName = o.StageName;
            row.amount = o.Amount;
            row.closeDate = o.CloseDate;
            row.ownerName = o.Owner != null ? o.Owner.Name : null;
            rows.add(row);
        }
        return rows;
    }

    /**
     * Submits the given Opportunity records to their default approval process.
     * Uses allOrNone=false so partial success is honoured.
     */
    @AuraEnabled
    public static List<BulkResult> submitForApproval(List<Id> recordIds, String comments) {
        List<BulkResult> results = new List<BulkResult>();
        if (recordIds == null || recordIds.isEmpty()) {
            return results;
        }

        List<Approval.ProcessSubmitRequest> requests = new List<Approval.ProcessSubmitRequest>();
        for (Id recordId : recordIds) {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(recordId);
            if (String.isNotBlank(comments)) {
                req.setComments(comments);
            }
            req.setSubmitterId(UserInfo.getUserId());
            requests.add(req);
        }

        Approval.ProcessResult[] processResults;
        try {
            processResults = Approval.process(requests, false);
        } catch (Exception e) {
            for (Id recordId : recordIds) {
                results.add(new BulkResult(recordId, false, e.getMessage()));
            }
            return results;
        }

        for (Integer i = 0; i < processResults.size(); i++) {
            Approval.ProcessResult pr = processResults[i];
            Id recordId = recordIds[i];
            if (pr.isSuccess()) {
                results.add(new BulkResult(recordId, true, null));
            } else {
                results.add(new BulkResult(recordId, false, formatErrors(pr.getErrors())));
            }
        }
        return results;
    }

    /**
     * Returns approval workitems pending action by the running user where the
     * target object is an Opportunity.
     *
     * Note: ProcessInstanceWorkitem.ActorId resolves either to a User Id or a
     * Group Id (queue / role). Only direct user assignment is filtered here;
     * delegation via groups is intentionally out of scope for this sample.
     */
    @AuraEnabled(cacheable=true)
    public static List<PendingApprovalRow> getMyPendingOpportunityApprovals() {
        Id runningUserId = UserInfo.getUserId();

        List<ProcessInstanceWorkitem> workitems = [
            SELECT Id, ActorId,
                   ProcessInstance.TargetObjectId,
                   ProcessInstance.CreatedDate,
                   ProcessInstance.SubmittedBy.Name,
                   ProcessInstance.TargetObject.Type
            FROM ProcessInstanceWorkitem
            WHERE ActorId = :runningUserId
              AND ProcessInstance.Status = 'Pending'
            ORDER BY ProcessInstance.CreatedDate DESC
            LIMIT 1000
        ];

        Set<Id> oppIds = new Set<Id>();
        for (ProcessInstanceWorkitem w : workitems) {
            if (w.ProcessInstance.TargetObject.Type == 'Opportunity') {
                oppIds.add(w.ProcessInstance.TargetObjectId);
            }
        }

        Map<Id, Opportunity> oppById = new Map<Id, Opportunity>();
        if (!oppIds.isEmpty()) {
            oppById = new Map<Id, Opportunity>([
                SELECT Id, Name, StageName, Amount
                FROM Opportunity
                WHERE Id IN :oppIds
            ]);
        }

        List<PendingApprovalRow> rows = new List<PendingApprovalRow>();
        for (ProcessInstanceWorkitem w : workitems) {
            if (w.ProcessInstance.TargetObject.Type != 'Opportunity') {
                continue;
            }
            Opportunity o = oppById.get(w.ProcessInstance.TargetObjectId);
            if (o == null) {
                continue;
            }
            PendingApprovalRow row = new PendingApprovalRow();
            row.workitemId = w.Id;
            row.recordId = o.Id;
            row.name = o.Name;
            row.stageName = o.StageName;
            row.amount = o.Amount;
            row.submitterName = w.ProcessInstance.SubmittedBy != null
                ? w.ProcessInstance.SubmittedBy.Name : null;
            row.submittedDate = w.ProcessInstance.CreatedDate;
            rows.add(row);
        }
        return rows;
    }

    /**
     * Approves or rejects a list of approval workitems.
     *
     * @param workitemIds  ProcessInstanceWorkitem ids to act on.
     * @param action       'Approve' or 'Reject'.
     * @param comments     Optional comments applied to every workitem.
     */
    @AuraEnabled
    public static List<BulkResult> processWorkitems(List<Id> workitemIds, String action, String comments) {
        List<BulkResult> results = new List<BulkResult>();
        if (workitemIds == null || workitemIds.isEmpty()) {
            return results;
        }
        if (String.isBlank(action)
            || (action != 'Approve' && action != 'Reject')) {
            throw new AuraHandledException('action must be "Approve" or "Reject"');
        }

        List<Approval.ProcessWorkitemRequest> requests = new List<Approval.ProcessWorkitemRequest>();
        for (Id workitemId : workitemIds) {
            Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
            req.setWorkitemId(workitemId);
            req.setAction(action);
            if (String.isNotBlank(comments)) {
                req.setComments(comments);
            }
            requests.add(req);
        }

        Approval.ProcessResult[] processResults;
        try {
            processResults = Approval.process(requests, false);
        } catch (Exception e) {
            for (Id workitemId : workitemIds) {
                results.add(new BulkResult(workitemId, false, e.getMessage()));
            }
            return results;
        }

        for (Integer i = 0; i < processResults.size(); i++) {
            Approval.ProcessResult pr = processResults[i];
            Id workitemId = workitemIds[i];
            if (pr.isSuccess()) {
                results.add(new BulkResult(workitemId, true, null));
            } else {
                results.add(new BulkResult(workitemId, false, formatErrors(pr.getErrors())));
            }
        }
        return results;
    }

    private static Integer normalizeMaxRows(Integer requested) {
        if (requested == null || requested <= 0) {
            return DEFAULT_MAX_ROWS;
        }
        return Math.min(requested, ABSOLUTE_MAX_ROWS);
    }

    private static String formatErrors(Database.Error[] errors) {
        if (errors == null || errors.size() == 0) {
            return 'Unknown error';
        }
        List<String> parts = new List<String>();
        for (Database.Error err : errors) {
            parts.add(err.getMessage());
        }
        return String.join(parts, '; ');
    }
}
