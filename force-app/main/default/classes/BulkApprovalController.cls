/**
 * Apex controller for the bulk approval LWCs.
 *
 * Generic across any sObject that has at least one active approval process.
 * Object selection is data-driven from ProcessDefinition; per-object record
 * queries are built dynamically using the entity's name field and (when
 * available) OwnerId, so the same controller backs Opportunity, Account,
 * custom objects, and so on.
 *
 * Approval calls go through Approval.process(...) with allOrNone=false so
 * that partial success is preserved and per-record errors can be returned to
 * the UI.
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

    /** Object descriptor surfaced to the object picker. */
    public class ApprovalObject {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;

        public ApprovalObject(String apiName, String label) {
            this.apiName = apiName;
            this.label = label;
        }
    }

    /** Submit-screen payload: object metadata + rows. */
    public class SubmittableData {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String nameField;
        @AuraEnabled public Boolean hasOwner;
        @AuraEnabled public List<RecordRow> rows;

        public SubmittableData() {
            this.rows = new List<RecordRow>();
        }
    }

    /** Generic row used by the submit screen. */
    public class RecordRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String ownerName;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    /** Row used by the approval screen. */
    public class PendingApprovalRow {
        @AuraEnabled public Id workitemId;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String submitterName;
        @AuraEnabled public Datetime submittedDate;
    }

    /**
     * Returns the distinct list of objects that have at least one active
     * approval process. Used to populate the object picker on both screens.
     */
    @AuraEnabled(cacheable=true)
    public static List<ApprovalObject> getApprovalEnabledObjects() {
        Set<String> keys = new Set<String>();
        for (ProcessDefinition pd : [
            SELECT TableEnumOrId
            FROM ProcessDefinition
            WHERE Type = 'Approval' AND State = 'Active'
            LIMIT 1000
        ]) {
            if (String.isNotBlank(pd.TableEnumOrId)) {
                keys.add(pd.TableEnumOrId);
            }
        }
        List<ApprovalObject> results = new List<ApprovalObject>();
        if (keys.isEmpty()) {
            return results;
        }

        Map<String, Schema.SObjectType> globalDesc = Schema.getGlobalDescribe();
        Set<String> unresolved = new Set<String>();
        for (String key : keys) {
            // Standard objects: TableEnumOrId equals the API name and resolves directly.
            Schema.SObjectType sot = globalDesc.get(key);
            if (sot != null) {
                Schema.DescribeSObjectResult dsr = sot.getDescribe();
                results.add(new ApprovalObject(dsr.getName(), dsr.getLabel()));
            } else {
                unresolved.add(key);
            }
        }

        // Custom objects: TableEnumOrId is the 15-char object-type id which
        // matches EntityDefinition.DurableId.
        if (!unresolved.isEmpty()) {
            for (EntityDefinition ed : [
                SELECT QualifiedApiName, Label, DurableId
                FROM EntityDefinition
                WHERE DurableId IN :unresolved
                LIMIT 200
            ]) {
                results.add(new ApprovalObject(ed.QualifiedApiName, ed.Label));
            }
        }

        return sortByLabel(results);
    }

    /**
     * Returns records of the given object that the running user can submit
     * for approval — i.e. owned/created by them and not currently in a
     * pending approval process.
     */
    @AuraEnabled(cacheable=true)
    public static SubmittableData getSubmittableRecords(String objectApiName, Integer maxRows) {
        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('objectApiName は必須です');
        }
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            throw new AuraHandledException('未知のオブジェクト: ' + objectApiName);
        }
        Schema.DescribeSObjectResult dsr = sot.getDescribe();
        if (!dsr.isQueryable() || !dsr.isAccessible()) {
            throw new AuraHandledException(dsr.getName() + ' を参照できません');
        }

        Integer limitRows = normalizeMaxRows(maxRows);
        Id userId = UserInfo.getUserId();
        String resolvedApi = dsr.getName();

        Map<String, Schema.SObjectField> fields = dsr.fields.getMap();
        String nameField = findNameField(fields);
        Boolean hasOwner = fields.containsKey('OwnerId');
        Boolean hasCreatedBy = fields.containsKey('CreatedById');

        Set<Id> pendingIds = new Set<Id>();
        for (ProcessInstance pi : [
            SELECT TargetObjectId
            FROM ProcessInstance
            WHERE Status = 'Pending'
              AND TargetObject.Type = :resolvedApi
            LIMIT 50000
        ]) {
            pendingIds.add(pi.TargetObjectId);
        }

        List<String> selectFields = new List<String>{ 'Id' };
        if (nameField != null) {
            selectFields.add(nameField);
        }
        selectFields.add('CreatedDate');
        selectFields.add('LastModifiedDate');
        if (hasOwner) {
            selectFields.add('OwnerId');
            selectFields.add('Owner.Name');
        }

        String filterField;
        if (hasOwner) {
            filterField = 'OwnerId';
        } else if (hasCreatedBy) {
            filterField = 'CreatedById';
        } else {
            // Nothing safe to filter on — return empty rather than dump every record.
            SubmittableData empty = new SubmittableData();
            empty.objectApiName = resolvedApi;
            empty.objectLabel = dsr.getLabel();
            empty.nameField = nameField;
            empty.hasOwner = false;
            return empty;
        }

        String orderField = nameField != null ? nameField : 'CreatedDate';
        String soql = 'SELECT ' + String.join(selectFields, ', ')
            + ' FROM ' + resolvedApi
            + ' WHERE ' + filterField + ' = :userId'
            + (pendingIds.isEmpty() ? '' : ' AND Id NOT IN :pendingIds')
            + ' ORDER BY ' + orderField + ' ASC NULLS LAST'
            + ' LIMIT :limitRows';

        List<SObject> records = Database.query(soql);

        SubmittableData data = new SubmittableData();
        data.objectApiName = resolvedApi;
        data.objectLabel = dsr.getLabel();
        data.nameField = nameField;
        data.hasOwner = hasOwner;

        for (SObject r : records) {
            RecordRow row = new RecordRow();
            row.id = (Id) r.get('Id');
            row.name = nameField != null ? String.valueOf(r.get(nameField)) : (String) r.get('Id');
            row.createdDate = (Datetime) r.get('CreatedDate');
            row.lastModifiedDate = (Datetime) r.get('LastModifiedDate');
            if (hasOwner) {
                SObject owner = r.getSObject('Owner');
                if (owner != null) {
                    row.ownerName = (String) owner.get('Name');
                }
            }
            data.rows.add(row);
        }
        return data;
    }

    /**
     * Submits the given records to their default approval process.
     * Works for any sObject; allOrNone=false preserves partial success.
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
     * Returns approval workitems pending action by the running user across
     * all object types — or filtered to one object when objectApiName is
     * supplied. Each row carries the resolved record name and object label.
     */
    @AuraEnabled(cacheable=true)
    public static List<PendingApprovalRow> getMyPendingApprovals(String objectApiName) {
        Id userId = UserInfo.getUserId();
        Boolean filterByType = String.isNotBlank(objectApiName);
        String typeFilter = objectApiName;

        List<ProcessInstanceWorkitem> workitems;
        if (filterByType) {
            workitems = [
                SELECT Id,
                       ProcessInstance.TargetObjectId,
                       ProcessInstance.CreatedDate,
                       ProcessInstance.SubmittedBy.Name,
                       ProcessInstance.TargetObject.Type
                FROM ProcessInstanceWorkitem
                WHERE ActorId = :userId
                  AND ProcessInstance.Status = 'Pending'
                  AND ProcessInstance.TargetObject.Type = :typeFilter
                ORDER BY ProcessInstance.CreatedDate DESC
                LIMIT 1000
            ];
        } else {
            workitems = [
                SELECT Id,
                       ProcessInstance.TargetObjectId,
                       ProcessInstance.CreatedDate,
                       ProcessInstance.SubmittedBy.Name,
                       ProcessInstance.TargetObject.Type
                FROM ProcessInstanceWorkitem
                WHERE ActorId = :userId
                  AND ProcessInstance.Status = 'Pending'
                ORDER BY ProcessInstance.CreatedDate DESC
                LIMIT 1000
            ];
        }

        // Bucket target ids by object type for one query per type.
        Map<String, Set<Id>> idsByType = new Map<String, Set<Id>>();
        for (ProcessInstanceWorkitem w : workitems) {
            String t = w.ProcessInstance.TargetObject.Type;
            if (!idsByType.containsKey(t)) {
                idsByType.put(t, new Set<Id>());
            }
            idsByType.get(t).add(w.ProcessInstance.TargetObjectId);
        }

        Map<String, Schema.SObjectType> globalDesc = Schema.getGlobalDescribe();
        Map<Id, Map<String, String>> recordInfoById = new Map<Id, Map<String, String>>();

        for (String t : idsByType.keySet()) {
            Schema.SObjectType sot = globalDesc.get(t);
            if (sot == null) {
                continue;
            }
            Schema.DescribeSObjectResult dsr = sot.getDescribe();
            if (!dsr.isQueryable() || !dsr.isAccessible()) {
                continue;
            }
            String nameField = findNameField(dsr.fields.getMap());
            Set<Id> ids = idsByType.get(t);
            String soql = 'SELECT Id'
                + (nameField != null ? ', ' + nameField : '')
                + ' FROM ' + t + ' WHERE Id IN :ids';
            for (SObject so : Database.query(soql)) {
                Map<String, String> meta = new Map<String, String>();
                meta.put('name', nameField != null
                    ? String.valueOf(so.get(nameField))
                    : (String) so.get('Id'));
                meta.put('objectApiName', t);
                meta.put('objectLabel', dsr.getLabel());
                recordInfoById.put((Id) so.get('Id'), meta);
            }
        }

        List<PendingApprovalRow> rows = new List<PendingApprovalRow>();
        for (ProcessInstanceWorkitem w : workitems) {
            Id targetId = w.ProcessInstance.TargetObjectId;
            Map<String, String> meta = recordInfoById.get(targetId);
            if (meta == null) {
                continue;
            }
            PendingApprovalRow row = new PendingApprovalRow();
            row.workitemId = w.Id;
            row.recordId = targetId;
            row.name = meta.get('name');
            row.objectApiName = meta.get('objectApiName');
            row.objectLabel = meta.get('objectLabel');
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

    private static String findNameField(Map<String, Schema.SObjectField> fields) {
        for (Schema.SObjectField f : fields.values()) {
            Schema.DescribeFieldResult d = f.getDescribe();
            if (d.isNameField()) {
                return d.getName();
            }
        }
        return null;
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

    private static List<ApprovalObject> sortByLabel(List<ApprovalObject> input) {
        Map<String, List<ApprovalObject>> byKey = new Map<String, List<ApprovalObject>>();
        List<String> keys = new List<String>();
        for (ApprovalObject o : input) {
            String key = ((o.label == null ? '' : o.label.toLowerCase())) + '|' + o.apiName;
            if (!byKey.containsKey(key)) {
                byKey.put(key, new List<ApprovalObject>());
                keys.add(key);
            }
            byKey.get(key).add(o);
        }
        keys.sort();
        List<ApprovalObject> sorted = new List<ApprovalObject>();
        for (String k : keys) {
            sorted.addAll(byKey.get(k));
        }
        return sorted;
    }
}
