//
//  CKDownloadManager.m
//  DownloadManager
//
//  Created by Mac on 14-5-21.
//  Copyright (c) 2014年 Mac. All rights reserved.
//

#import "CKDownloadManager.h"
#import "CKDownloadPathManager.h"
#import "LKDBHelper.h"
#import "Reachability.h"
#import "MBFlatAlertView.h"
#import "NSObject+LKModel.h"

typedef void(^AlertBlock)(id alertview);

#define  ORIGIN_URL(_request_) _request_.originalURL ?  _request_.originalURL : _request_.url
#define  B_TO_M(_x_)  _x_/1024.f/1024.f
#define  CHECK_NETWORK_HOSTNAME  @"www.baidu.com"

static Class ModelClass=nil;
static BOOL  ShouldContinueDownloadBackground=NO;


@interface CKDownloadManager()<ASIProgressDelegate,ASIHTTPRequestDelegate>
{
    NSMutableArray * _filterDownloadingEntities;
    NSMutableArray * _filterDownloadCompleteEntities;
}
@end

@implementation CKDownloadManager
@dynamic downloadEntities,filterParams;



#pragma mark - class method


+ (instancetype)sharedInstance {
    static CKDownloadManager *_sharedInstance= nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[CKDownloadManager alloc] init];
    });
    
    return _sharedInstance;
}


-(id) init
{
    
    self = [super init];
    if (!self) {
        return nil;
    }
    
    if(ModelClass==nil)
        ModelClass=[CKDownloadBaseModel  class];
    
    [self observeNetWorkState];
    
    //data base
    LKDBHelper* globalHelper = [LKDBHelper getUsingLKDBHelper];
    [globalHelper createTableWithModelClass:[ModelClass class]];
    
    _queue = [[ASINetworkQueue alloc] init];
    _queue.maxConcurrentOperationCount=4;
    [_queue setShowAccurateProgress:YES];
    [_queue go];
    
    
    _operationsDic=[NSMutableDictionary dictionary];
    _targetBlockDic=[NSMutableDictionary dictionary];
    _downloadEntityAry=[NSMutableArray array];
    _downloadEntityDic=[NSMutableDictionary dictionary];
    _downloadCompleteEnttiyDic=[NSMutableDictionary dictionary];
    _downloadCompleteEntityAry=[NSMutableArray array];
    
    
    
    NSString * conditionNotFinish=[self downloadingCondition];
    NSString * conditionFinish=[self downloadFinishCondition];
    NSMutableArray * readyDownloadItems= [[LKDBHelper getUsingLKDBHelper] search:ModelClass where:conditionNotFinish orderBy:nil offset:0 count:0];
    NSMutableArray * finishDownloadItems =[[[LKDBHelper getUsingLKDBHelper] search:ModelClass where:conditionFinish orderBy:nil offset:0 count:0] copy];
    
    for (id<CKDownloadModelProtocal> emEntity in readyDownloadItems) {
        
        NSURL * url=[NSURL URLWithString:emEntity.URLString];
        float downloadSize=B_TO_M([CKDownloadPathManager downloadContentSizeWithURL:url]);
        emEntity.downloadContentSize=downloadSize ==0 ? @"" : [NSString stringWithFormat:@"%f",downloadSize];
        
        
        [[LKDBHelper getUsingLKDBHelper] insertToDB:emEntity];
        [_downloadEntityDic setObject:emEntity forKey:url];
        [_downloadEntityAry addObject:emEntity];
        
        if(emEntity.downloadState==kDSDownloading)
        {
            if([self isWifi])
            {
                [self downloadExistTaskWithURL:[NSURL URLWithString:emEntity.URLString]];
            }
            else
            {
                emEntity.completeState=@"2";
                [[LKDBHelper getUsingLKDBHelper] updateToDB:emEntity where:nil];
            }
        }
        

    }
    
    
    for (id<CKDownloadModelProtocal> emEntity in finishDownloadItems) {
        
        NSURL * url=[NSURL URLWithString:emEntity.URLString];
        
        [_downloadCompleteEntityAry addObject:emEntity];
        [_downloadCompleteEnttiyDic setObject:emEntity forKey:url];
    }
    
    
    //whether or not the Request is continue, the Request clear old and create new to download. This strategy in order to deal with request canl in background task.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    
    return self;

}

+(void) setModel:(Class )modelClass
{
    ModelClass=modelClass;
}

+(void) setShouldContinueDownloadBackground:(BOOL)isContinue
{
    ShouldContinueDownloadBackground=isContinue;
}



#pragma mark - instance method


-(void) startDownloadWithURL:(NSURL *)url  entity:(id<CKDownloadModelProtocal>)entity
{
    //如果已经在下载列表 返回
    if([[LKDBHelper getUsingLKDBHelper] searchSingle:[ModelClass class] where:@{URL_LINK_STRING: url.absoluteString} orderBy:nil])
    {
            return ;
    }
    
    
    if([self isWWAN])
    {
    
        [self showWWANWarningWithDoneBlock:^(id alertView) {
            [self addNewTask:url entity:entity];
            [self downloadExistTaskWithURL:url];
        } cancelBlock:nil];
    }
    else if([self isWifi])
    {
        [self addNewTask:url entity:entity];
        [self downloadExistTaskWithURL:url];
    }
    else
    {
        [self alertWhenNONetwork];
    }

}



-(void)attachTarget:(id)target ProgressBlock:(DownloadProgressBlock)block URL:(NSURL *)URL
{
    CKDownHandler * oldHandler=[_targetBlockDic objectForKey:URL];
    if(target && oldHandler.target==target)
        return ;
    
    
    CKDownHandler * handler=[[CKDownHandler alloc] init];
    handler.target=target;
    handler.progressBlock=block;
    
    [_targetBlockDic setObject:handler forKey:URL];
}

-(void) setMaxCurrentCount:(NSInteger)count
{
    _queue.maxConcurrentOperationCount=count;
}


-(void) pauseWithURL:(NSURL *)url
{
    ASIHTTPRequest * request=[_operationsDic objectForKey:url];
    if(request)
    {
        
        id<CKDownloadModelProtocal> model=[_downloadEntityDic objectForKey:url];
        model.completeState=@"2";
        [[LKDBHelper getUsingLKDBHelper] updateToDB:model where:nil];
        
        [request clearDelegatesAndCancel];
        
        [self excuteStatusChangedBlock:url];
        
    }
}


-(void) resumWithURL:(NSURL *)url
{
    if([self isWWAN])
    {
        [self showWWANWarningWithDoneBlock:^(id alertView) {
            [self resumTaskWithURL:url];
        } cancelBlock:nil];
    }
    else if([self isWifi])
    {
        [self resumTaskWithURL:url];
    }
    else
    {
        [self alertWhenNONetwork];
    }
}


-(void) deleteWithURL:(NSURL *)url
{
    BOOL  isCompleteTask=NO;
    id<CKDownloadModelProtocal>  model=nil;
    NSInteger index=-1;
    
    id<CKDownloadModelProtocal>  modelFinished=[_downloadCompleteEnttiyDic objectForKey:url];
    id<CKDownloadModelProtocal>  modelNotFinished=[_downloadEntityDic objectForKey:url];
    if(modelFinished)
    {
        
        model=modelFinished;
        
        index=[_downloadCompleteEntityAry indexOfObject:modelFinished];
        
        [[LKDBHelper getUsingLKDBHelper] deleteToDB:modelFinished];
        [_downloadCompleteEntityAry removeObject:modelFinished];
        [_downloadCompleteEnttiyDic removeObjectForKey:url];
        
        
        if(self.filterParams)
        {
            if([_filterDownloadCompleteEntities containsObject:model])
            {
                index=[_filterDownloadCompleteEntities indexOfObject:model];
                [_filterDownloadCompleteEntities removeObject:model];
            }
        }
        
        isCompleteTask=YES;
        
    }
    else if([_downloadEntityDic objectForKey:url])
    {
        model=modelNotFinished;
        
        index=[_downloadEntityAry indexOfObject:modelNotFinished];
        
        [[LKDBHelper getUsingLKDBHelper] deleteToDB:modelNotFinished];
        [_downloadEntityAry removeObject:modelNotFinished];
        [_downloadEntityDic removeObjectForKey:url];
        

        if(self.filterParams)
        {
            if([_filterDownloadingEntities containsObject:model])
            {
                index=[_filterDownloadingEntities indexOfObject:model];
                [_filterDownloadingEntities removeObject:model];
            }
        }
        
        isCompleteTask=NO;
    }
    
    
    [CKDownloadPathManager removeFileWithURL:url];
    
    if(index >=0)
    {
    
        if(self.downloadDeletedBlock)
            self.downloadDeletedBlock(model,index,isCompleteTask);
    }
}



#pragma mark - private method
-(void) initializeFilterEntities
{
    if(_filterDownloadingEntities==nil)
    {
        NSPredicate * predicate=[self createConditinWithCondition:[self filterDownloadingCondition],self.filterParams,nil];
        _filterDownloadingEntities= [[_downloadEntityAry filteredArrayUsingPredicate:predicate] mutableCopy];
    }
    
    if(_filterDownloadCompleteEntities==nil)
    {
        NSPredicate * predicate=[self createConditinWithCondition:[self filterDonwloadFinishedCondition],self.filterParams,nil];
        _filterDownloadCompleteEntities= [[_downloadCompleteEntityAry filteredArrayUsingPredicate:predicate] mutableCopy];
    }
}

//sql
-(NSString *) downloadingCondition
{
    NSString * conditionNotFinish=[NSString stringWithFormat:@"%@ !='1'",IS_DOWNLOAD_COMPLETE];
    return conditionNotFinish;
}


-(NSString *) downloadFinishCondition
{
    NSString * conditionFinish=[NSString stringWithFormat:@"%@ ='1'",IS_DOWNLOAD_COMPLETE];
    return conditionFinish;
}

//filter predicate
-(NSString *) filterDownloadingCondition
{
    NSString * conditionFinish=[NSString stringWithFormat:@"%@ !='1'",@"completeState"];
    return conditionFinish;
}


-(NSString *) filterDonwloadFinishedCondition
{
    NSString * conditionFinish=[NSString stringWithFormat:@"%@ ='1'",@"completeState"];
    return conditionFinish;
}


-(NSPredicate * ) createConditinWithCondition:(NSString *) condition, ...
{
    NSMutableString * finalCondition=[NSMutableString stringWithFormat:@"%@",condition];
    
    va_list args;
    va_start(args, condition);
    
    if(condition)
    {
        id params;
        while ((params=va_arg(args, id))) {
            if([condition isKindOfClass:[NSDictionary class]])
            {
                [finalCondition appendString:[self createConditionWithParams:(NSDictionary*)condition]];
            }
            else if([condition isKindOfClass:[NSString class]])
            {
                [finalCondition appendFormat:@"AND %@",params];
            }
        }
    }
    
    va_end(args);
    
    return [NSPredicate predicateWithFormat:finalCondition];
}


-(NSString *) createConditionWithParams:(NSDictionary*) params
{
    NSMutableString * result=[NSMutableString string];
    NSArray * allKeys=params.allKeys;
    for (NSString * emKey in allKeys) {
        NSString * value=[params objectForKey:emKey];
        [result appendFormat:@"AND %@ ='%@'",emKey,value];
    }
    
    return result;
}

-(void) downloadExistTaskWithURL:(NSURL *) url
{

    NSString * toPath=nil;
    NSString * tmpPath=nil;
    [CKDownloadPathManager SetURL:url toPath:&toPath tempPath:&tmpPath];
    
    ASIHTTPRequest * oldRequest=[_operationsDic objectForKey:url];
    if(oldRequest)
    {
        [oldRequest clearDelegatesAndCancel];
    }
    
    
    ASIHTTPRequest * request=[ASIHTTPRequest requestWithURL:url];
    request.downloadDestinationPath=toPath;
    request.temporaryFileDownloadPath=tmpPath;
    request.allowResumeForFileDownloads=YES;
    request.showAccurateProgress=YES;
    request.delegate=self;
    request.downloadProgressDelegate=self;
    request.shouldContinueWhenAppEntersBackground=ShouldContinueDownloadBackground;
    request.numberOfTimesToRetryOnTimeout=INT_MAX;

    [_operationsDic setObject:request forKey:url];
    [_queue addOperation:request];
    
    
    [self excuteStatusChangedBlock:url];
}


-(void) addNewTask:(NSURL *) url  entity:(id<CKDownloadModelProtocal>) entity
{
    
    NSString * toPath=nil;
    NSString * tmpPath=nil;
    [CKDownloadPathManager SetURL:url toPath:&toPath tempPath:&tmpPath];
    
    id<CKDownloadModelProtocal>  model=nil;
    if(entity)
    {
        model=entity;
    }
    else
    {
        model=[[ModelClass alloc] init];
    }
    model.URLString=url.absoluteString;
    model.downloadFinalPath=toPath;
    model.completeState=@"0";
    if(model.title.length==0)
    {
        model.title=[url lastPathComponent];
    }
    
    [[LKDBHelper getUsingLKDBHelper] insertToDB:model];
    
    [_downloadEntityDic setObject:model forKey:url];
    [_downloadEntityAry addObject:model];
    
    int index=0;
    
    if(self.filterParams)
    {
        NSPredicate * predicate=[self createConditinWithCondition:self.filterParams,nil];
        BOOL result=[predicate evaluateWithObject:model];
        if (result) {
            [_filterDownloadingEntities addObject:model];
            index=_filterDownloadingEntities.count-1;
            
            if(self.downloadStartBlock)
                self.downloadStartBlock(model,index);
        }
    }
    else
    {
        index=_downloadEntityAry.count-1;
        
        if(self.downloadStartBlock)
            self.downloadStartBlock(model,index);
    }
}


-(void) resumTaskWithURL:(NSURL *) url
{
    id<CKDownloadModelProtocal> model=[_downloadEntityDic objectForKey:url];
    model.completeState=@"0";
    [[LKDBHelper getUsingLKDBHelper] updateToDB:model where:nil];
    
    [self downloadExistTaskWithURL:url];
}

-(BOOL) isWifi
{
    Reachability * rb =[Reachability reachabilityForLocalWiFi];
    return  rb.isReachableViaWiFi;
}

-(BOOL) isWWAN
{
    Reachability * rb =[Reachability reachabilityForInternetConnection];
    return  rb.isReachableViaWWAN;
}


-(void) alertWhenNONetwork
{
    MBFlatAlertView * alertview=[self alertViewWithTitle:@"提示" message:@"请检查您的网络连接!" cancelButtonTitle:@"确定" cancelBlock:^{
        
    }];
    [alertview addToDisplayQueue];
}

-(void) showWWANWarningWithDoneBlock:(AlertBlock) block cancelBlock:(MBFlatAlertButtonAction) cancelBlock
{
    MBFlatAlertView * alert=[self alertViewWithTitle:@"提示" message:@"您正在使用2G/3G网络，是否继续下载？" cancelButtonTitle:@"取消" cancelBlock:^{
        if(cancelBlock)
            cancelBlock();
    }];
    
    __weak typeof(alert)weakAlert = alert;

    [alert addButtonWithTitle:@"确定" type:MBFlatAlertButtonTypeNormal action:^(){
        
        if(block)
            block(weakAlert);
        
        [weakAlert dismiss];
    }];
    
    [alert addToDisplayQueue];
}


-(MBFlatAlertView * ) alertViewWithTitle:(NSString *) title message:(NSString * ) message cancelButtonTitle:(NSString *) cancelTitle cancelBlock:(MBFlatAlertButtonAction) cancelBlock
{
    MBFlatAlertView * alertview=[MBFlatAlertView alertWithTitle:title detailText:message cancelTitle:cancelTitle cancelBlock:^{
        if(cancelBlock)
            cancelBlock();
    }];
    return alertview ;
}


//network status
-(void) observeNetWorkState
{
    Reachability * rb =[Reachability reachabilityWithHostname:CHECK_NETWORK_HOSTNAME];
    rb.reachableBlock=^(Reachability * reachability){
        if([reachability isReachableViaWWAN])
        {
            [_queue setSuspended:YES];
            [self showWWANWarningWithDoneBlock:^(id alertview) {
                [_queue go];
            } cancelBlock:^{
                [self pauseAll];
            }];
        }
        
        if([reachability isReachableViaWiFi])
        {
            [self resumAll];
        }
    };
    
    rb.unreachableBlock=^(Reachability * reachability){
        [self pauseAll];
        [self alertWhenNONetwork];
    };
    
    [rb startNotifier];
    
}



-(void) excuteStatusChangedBlock:(NSURL*) url
{
    if(self.downloadStatusChangedBlock)
    {
        id<CKDownloadModelProtocal> model=[_downloadEntityDic objectForKey:url];
        CKDownHandler* handler=[_targetBlockDic objectForKey:url];
        if([handler.target isKindOfClass:[UITableView class]])
        {
            
            NSInteger index=[self.downloadEntities indexOfObject:model];
            NSIndexPath * indexPath=[NSIndexPath indexPathForRow:index inSection:0];
            UITableViewCell * cell=[handler.target cellForRowAtIndexPath:indexPath];
            
            self.downloadStatusChangedBlock(model,cell);
        }
        else
        {
            self.downloadStatusChangedBlock(model,handler.target);
        }
    }

}

-(void) pauseAll
{
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        
        for (NSURL * emURL in [_operationsDic allKeys]) {
            id<CKDownloadModelProtocal> model=[_downloadEntityDic objectForKey:emURL];
            if(model.downloadState==kDSDownloading){
                [self pauseWithURL:emURL];
            }
        }
    });
    
}

-(void) resumAll
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        
        for (NSURL * emURL in [_operationsDic allKeys]) {
            id<CKDownloadModelProtocal> model=[_downloadEntityDic objectForKey:emURL];
            if(model.downloadState==kDSDownloading)
            {
                [self resumWithURL:emURL];
            }
        }
    });
}


#pragma mark - ASI delegate
-(void) requestStarted:(ASIHTTPRequest *)request
{
#if DEBUG
    NSLog(@"%@ 开始下载",request.url);
#endif
}

-(void) request:(ASIHTTPRequest *)request didReceiveResponseHeaders:(NSDictionary *)responseHeaders{
    //record totol cotnent
    
    if([_downloadEntityDic objectForKey:request.originalURL])
    {
        float fileLength = request.contentLength+request.partialDownloadSize;
        
        id<CKDownloadModelProtocal>  model=[_downloadEntityDic objectForKey:ORIGIN_URL(request)];
        model.totalCotentSize=[NSString stringWithFormat:@"%f",B_TO_M(fileLength)];
        [[LKDBHelper getUsingLKDBHelper] updateToDB:model where:nil];
    }
}


-(void) requestFinished:(ASIHTTPRequest *)request
{
    id<CKDownloadModelProtocal>  model=[_downloadEntityDic objectForKey:ORIGIN_URL(request)];
    if(model)
    {
        NSInteger index,completeIndex;
        if(self.filterParams)
        {
            if(![_filterDownloadingEntities containsObject:model])
                return ;
            index=[_filterDownloadingEntities indexOfObject:model];
            completeIndex= _filterDownloadCompleteEntities.count;
            
            [_filterDownloadingEntities removeObject:model];
            [_filterDownloadCompleteEntities addObject:model];
        }
        else
        {
            index=[self.downloadEntities indexOfObject:model];
            completeIndex=self.downloadCompleteEntities.count;
        }
        
        model.completeState=@"1";
        [[LKDBHelper getUsingLKDBHelper] updateToDB:model where:nil];
        
        
        [_targetBlockDic removeObjectForKey:ORIGIN_URL(request)];
        [_operationsDic removeObjectForKey:ORIGIN_URL(request)];
        
        [_downloadEntityAry removeObject:model];
        [_downloadEntityDic removeObjectForKey:ORIGIN_URL(request)];
        
       
        [_downloadCompleteEntityAry addObject:model];
        [_downloadCompleteEnttiyDic setObject:model forKey:ORIGIN_URL(request)];
        


        if(self.downloadCompleteBlock)
        {
            if(self.filterParams)
            {
                BOOL isFiltered=[_filterDownloadCompleteEntities containsObject:model];
                if(isFiltered)
                {
                    self.downloadCompleteBlock(model,index,completeIndex,isFiltered);
                }
            }
            else
            {
                self.downloadCompleteBlock(model,index,completeIndex,YES);
            }
        }
    }
}

-(void) requestFailed:(ASIHTTPRequest *)request
{

}


-(void) request:(ASIHTTPRequest *)request didReceiveBytes:(long long)bytes
{
    float currentSize=[request totalBytesRead]+[request partialDownloadSize];
    float totalContentSize=[request partialDownloadSize]+request.contentLength;
    
    float progress=currentSize/totalContentSize;
    
    id<CKDownloadModelProtocal>  model=[_downloadEntityDic objectForKey:ORIGIN_URL(request)];
    model.downloadContentSize=[NSString stringWithFormat:@"%f",B_TO_M(currentSize)];
    
    CKDownHandler * handler=[_targetBlockDic objectForKey:ORIGIN_URL(request)];
    if([handler.target isKindOfClass:[UITableView class]])
    {
        NSInteger index=[self.downloadEntities indexOfObject:model];
        NSIndexPath * indexPath=[NSIndexPath indexPathForRow:index inSection:0];
        UITableViewCell * cell=[handler.target cellForRowAtIndexPath:indexPath];
        
        if(cell)
        {
            handler.progressBlock(progress,B_TO_M(currentSize),B_TO_M(currentSize),cell);
        }
        
    }
    else
    {
        if(handler.target)
        {
            handler.progressBlock(progress,B_TO_M(currentSize),B_TO_M(currentSize),nil);
        }
    }
}




#pragma mark - dynamic method
-(NSArray*) downloadEntities
{
    if(self.filterParams)
    {
        return _filterDownloadingEntities;
    }
    return  [_downloadEntityAry copy];
}

-(NSArray*) downloadCompleteEntities
{
    if(self.filterParams)
    {
        return _filterDownloadCompleteEntities;
    }
    return  [_downloadCompleteEntityAry copy];
}


-(void) setFilterParams:(id)filterParams
{
    _filterParams=filterParams;
    [self initializeFilterEntities];
}

-(id)filterParams
{
    
    return  _filterParams;
}



#pragma mark -  Notification 
-(void) applicationWillEnterForeground
{
    [self resumAll];
}


@end
