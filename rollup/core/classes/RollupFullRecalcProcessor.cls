global abstract without sharing class RollupFullRecalcProcessor extends RollupAsyncProcessor.QueueableProcessor {
  protected final List<Rollup__mdt> rollupMetas;
  protected final Set<String> objIds = new Set<String>();
  protected String queryString;

  private final RollupFullRecalcProcessor postProcessor;
  private final Map<Id, SObject> parentRecordsToClear = new Map<Id, SObject>();
  private final List<RollupFullRecalcProcessor> cabooses = new List<RollupFullRecalcProcessor>();
  private Map<Schema.SObjectType, Set<Id>> typeToOldIntermediateGrandparents;
  private Boolean hasProcessedParentRecords = false;

  protected RollupFullRecalcProcessor(
    String queryString,
    InvocationPoint invokePoint,
    List<Rollup__mdt> rollupMetas,
    SObjectType calcItemType,
    Set<String> recordIds,
    RollupFullRecalcProcessor postProcessor
  ) {
    super(invokePoint);
    this.isFullRecalc = true;
    this.calcItemType = calcItemType;
    this.queryString = queryString;
    this.rollupMetas = rollupMetas;
    this.recordIds = recordIds;
    this.postProcessor = postProcessor;
    this.processMetadata();
  }

  public void addCaboose(RollupFullRecalcProcessor caboose) {
    this.cabooses.add(caboose);
  }

  public void addMetadata(Rollup__mdt meta) {
    this.rollupMetas.add(meta);
  }

  public void setQuery(String replacementQuery) {
    this.queryString = replacementQuery;
  }

  public SObjectType getCalcItemType() {
    return this.calcItemType;
  }

  global override Rollup addLimit(Integer limitAmount, Schema.SObjectField calcItemRollupField) {
    for (Rollup__mdt rollupMeta : this.rollupMetas) {
      this.addLimitToMetadata(rollupMeta, limitAmount, calcItemRollupField);
    }
    return this;
  }

  global override Rollup addOrderBys(List<RollupOrderBy__mdt> orderBys, Schema.SObjectField calcItemRollupField) {
    for (Integer index = 0; index < this.rollupMetas.size(); index++) {
      Rollup__mdt rollupMeta = this.addOrderBys(this.rollupMetas[index], orderBys, calcItemRollupField);
      this.rollupMetas.set(index, rollupMeta);
    }
    return this;
  }

  global override Rollup modifyMetadata(Rollup__mdt template) {
    this.modifyMetadata(this.rollupMetas, template);
    return this;
  }

  public void finish() {
    if (this.cabooses.isEmpty() == false) {
      RollupFullRecalcProcessor conductor = this.cabooses.remove(0);
      for (Rollup__mdt meta : conductor.rollupMetas) {
        conductor.storeUniqueParentFields(meta);
      }
      for (RollupFullRecalcProcessor caboose : this.cabooses) {
        conductor.addCaboose(caboose);
      }
      this.setCurrentJobId(conductor.startAsyncWork());
    } else if (this.postProcessor != null) {
      this.logger.log('Starting post-full recalc processor', this.postProcessor, LoggingLevel.INFO);
      // chain jobs together so that if recalc job is being tracked within the Recalc Rollups app,
      // job continuity is established between the full recalc and then any downstream job that runs
      // (as the postProcessor)
      this.setCurrentJobId(this.postProcessor.runCalc());
    }
    if (this.hasProcessedParentRecords == false) {
      List<SObject> parentRecords = new List<SObject>();
      this.processParentFieldsToReset(parentRecords);
      this.getDML().doUpdate(parentRecords);
    }
  }

  public Set<String> getRecordIdentifiers() {
    return new Set<String>(this.recordIds);
  }

  public void trackParentRecord(SObject parent) {
    this.postProcessor?.recordIds.add(parent.Id);
  }

  public void storeParentFieldsToClear(List<SObject> parentRecordsToClear) {
    this.parentRecordsToClear.putAll(parentRecordsToClear);
  }

  public void processParentFieldsToReset(List<SObject> relatedParentRecords) {
    if (this.hasProcessedParentRecords || this.rollupControl.ShouldSkipResettingParentFields__c == true) {
      return;
    }
    this.hasProcessedParentRecords = true;
    Map<Id, SObject> relatedParentRecordsMap = new Map<Id, SObject>(relatedParentRecords);
    for (SObject parentRecordToReset : this.parentRecordsToClear.values()) {
      SObject relatedParentRecord = relatedParentRecordsMap.containsKey(parentRecordToReset.Id)
        ? relatedParentRecordsMap.get(parentRecordToReset.Id)
        : RollupCurrencyInfo.createNewRecord(parentRecordToReset);

      for (Rollup__mdt meta : this.rollupMetas) {
        if (relatedParentRecord.getSObjectType().getDescribe().getName() == meta.LookupObject__c) {
          relatedParentRecord.put(meta.RollupFieldOnLookupObject__c, null);
        }
      }

      relatedParentRecordsMap.put(relatedParentRecord.Id, relatedParentRecord);
    }
    relatedParentRecords.clear();
    relatedParentRecords.addAll(relatedParentRecordsMap.values());
    this.parentRecordsToClear.clear();
  }

  public void setOldIntermediateGrandparents(Map<Schema.SObjectType, Set<Id>> typeToOldIntermediateGrandparents) {
    this.typeToOldIntermediateGrandparents = typeToOldIntermediateGrandparents;
  }

  public Map<Schema.SObjectType, Set<Id>> getOldIntermediateGrandparents() {
    return this.typeToOldIntermediateGrandparents == null ? new Map<Schema.SObjectType, Set<Id>>() : this.typeToOldIntermediateGrandparents;
  }

  protected override RollupRepository preStart() {
    return new RollupRepository(this.runAsMode).setArg(this.objIds).setArg('recordIds', this.recordIds).setQuery(this.queryString);
  }

  protected List<RollupAsyncProcessor> getDelegatedFullRecalcRollups(List<SObject> calcItems) {
    for (Schema.SObjectType intermediateGrandparent : this.getOldIntermediateGrandparents().keySet()) {
      for (Id resetId : this.getOldIntermediateGrandparents().get(intermediateGrandparent)) {
        this.parentRecordsToClear.put(resetId, resetId.getSObjectType().newSObject(resetId));
      }
    }
    RollupAsyncProcessor processor = this.getAsyncRollup(this.rollupMetas, this.calcItemType, calcItems, new Map<Id, SObject>(), null, this.invokePoint);
    for (RollupAsyncProcessor innerRoll : processor.rollups) {
      innerRoll.fullRecalcProcessor = this;
      innerRoll.isFullRecalc = true;
      innerRoll.calcItems = calcItems;
    }
    this.fullRecalcProcessor = this;
    return processor.rollups;
  }

  protected virtual override Map<String, String> customizeToStringEntries(Map<String, String> props) {
    super.customizeToStringEntries(props);
    this.addToMap(props, 'Rollup Metadata', this.rollupMetas);
    this.addToMap(props, 'Query String', this.queryString);
    this.addToMap(props, 'Caboose Count', this.cabooses.size());
    return props;
  }

  protected override String getHashedContents() {
    return String.valueOf(this.rollupMetas);
  }

  protected override Boolean getCanRollupWithoutCustomSetting() {
    Boolean canRollupWithoutCustomSetting = false;
    for (Rollup__mdt rollupMeta : this.rollupMetas) {
      canRollupWithoutCustomSetting = rollupMeta.ShouldRunWithoutCustomSettingEnabled__c;
      // all included rollups need to have the override enabled; if even one does NOT, we can stop
      if (canRollupWithoutCustomSetting == false) {
        break;
      }
    }
    return canRollupWithoutCustomSetting;
  }

  private void processMetadata() {
    for (Rollup__mdt meta : this.rollupMetas) {
      if (meta.RollupControl__c != null) {
        RollupControl__mdt specificControl = this.getSpecificControl(meta.RollupControl__c);
        this.overrideParentRollupControlValues(specificControl);
      }
      this.runAsMode = RollupMetaPicklists.getAccessLevel(meta);
    }
  }
}
